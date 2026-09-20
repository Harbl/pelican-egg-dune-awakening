#!/bin/bash
# Regression harness for scripts/rotate-logs.sh.
#
#   bash scripts/tests/test-rotate-logs.sh
#
# Nothing trimmed the logs directory until now: a test server that had been up
# for months held a 10 GB director.log, and a reporter's production server
# 8.9 GB — the latter at the Director's DEFAULT level=info, so this is not a
# misconfiguration anyone had to make.
#
# The properties that matter, in order:
#   1. a log over the cap comes down;
#   2. the RECENT end survives (a log that vanishes mid-incident is its own
#      outage);
#   3. writers holding the file open keep writing into it — the whole reason
#      this truncates in place instead of renaming;
#   4. a log under the cap is not touched at all.

set -u

HERE="$(dirname "$(readlink -f "$0")")"
# Not named SCRIPTS: lib.sh redefines that to "$BASE/scripts" when sourced.
REPO_SCRIPTS="$(cd "$HERE/.." && pwd)"
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/logs"

export SOURCE="test"
DUNE_LOG_MAX_MB=2
DUNE_LOG_KEEP_MB=1
export DUNE_LOG_MAX_MB DUNE_LOG_KEEP_MB
# shellcheck source=/dev/null
source "$REPO_SCRIPTS/rotate-logs.sh" "$BASE"
set +e   # lib.sh exports `set -eu`; keep -u, drop -e so one red case isn't fatal

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

mb() { echo $(( $1 * 1024 * 1024 )); }
size_of() { stat -c %s "$1"; }

# A log with recognisable first and last lines, padded to `mb` megabytes.
make_log() {
  local f=$1 megs=$2
  { echo "OLDEST-LINE-MARKER"
    head -c "$(mb "$megs")" /dev/zero | tr '\0' 'x' | fold -w 200
    echo "NEWEST-LINE-MARKER"
  } > "$f"
}

echo "rotate-logs.sh"

# --- over the cap ---------------------------------------------------------

big="$LOGS/director.log"
make_log "$big" 4
before=$(size_of "$big")
rotate_one "$big"
after=$(size_of "$big")

if [ "$after" -lt "$before" ]; then
  ok "a log over the cap is trimmed ($(( before / 1024 / 1024 )) MB -> $(( after / 1024 / 1024 )) MB)"
else
  bad "a log over the cap is trimmed" "size unchanged at $before"
fi
if [ "$after" -le "$(mb 2)" ]; then
  ok "the trimmed size respects the keep setting"
else
  bad "the trimmed size respects the keep setting" "kept $after bytes for DUNE_LOG_KEEP_MB=1"
fi
if tail -c 4000 "$big" | grep -q "NEWEST-LINE-MARKER"; then
  ok "the recent end is what survives"
else
  bad "the recent end is what survives" "the newest line was dropped — the half an operator needs"
fi
if grep -q "OLDEST-LINE-MARKER" "$big"; then
  bad "the old head is dropped" "the oldest line is still there, so nothing was actually reclaimed"
else
  ok "the old head is dropped"
fi
if head -c 400 "$big" | grep -q "trimmed by rotate-logs.sh"; then
  ok "the file says it was trimmed, and when"
else
  bad "the file says it was trimmed, and when" "no marker line at the top"
fi

# --- under the cap --------------------------------------------------------

small="$LOGS/gateway.log"
make_log "$small" 1
sum_before=$(md5sum < "$small")
rotate_one "$small"
if [ "$(md5sum < "$small")" = "$sum_before" ]; then
  ok "a log under the cap is untouched"
else
  bad "a log under the cap is untouched" "a file below the threshold was rewritten"
fi

# --- the open-writer property --------------------------------------------
#
# Every service appends with O_APPEND (launch_bg in lib.sh). This is the case
# that rules out rename-based rotation: a renamed file leaves each daemon
# writing to an unlinked inode, so the disk never comes back and the visible
# log stays empty until the next restart.

live="$LOGS/text-router.log"
make_log "$live" 4
exec 9>>"$live"                       # a writer holding the file open, O_APPEND
rotate_one "$live"
echo "WRITE-AFTER-ROTATION" >&9
exec 9>&-
if grep -q "WRITE-AFTER-ROTATION" "$live"; then
  ok "an open writer keeps writing into the trimmed file"
else
  bad "an open writer keeps writing into the trimmed file" "the writer's output went somewhere else"
fi
if [ "$(size_of "$live")" -le "$(mb 2)" ]; then
  ok "no sparse hole left behind by the truncation"
else
  bad "no sparse hole left behind by the truncation" "file is $(size_of "$live") bytes after a 1 MB keep"
fi

# --- the sweep ------------------------------------------------------------

make_log "$LOGS/mock-k8s.log" 4
make_log "$LOGS/admin-http.log" 1
rotate_all
if [ "$(size_of "$LOGS/mock-k8s.log")" -le "$(mb 2)" ] && [ "$(size_of "$LOGS/admin-http.log")" -gt 0 ]; then
  ok "the sweep trims the big ones and leaves the small ones"
else
  bad "the sweep trims the big ones and leaves the small ones" "mock-k8s=$(size_of "$LOGS/mock-k8s.log") admin-http=$(size_of "$LOGS/admin-http.log")"
fi

# console.sh sources this file and keeps logging afterwards. An unconditional
# `export SOURCE` here would retag every later supervisor line as if the
# rotator had written it — wrong attribution in the one place an operator reads.
if [ "$SOURCE" = "test" ]; then
  ok "sourcing does not steal the caller's log tag"
else
  bad "sourcing does not steal the caller's log tag" "SOURCE became '$SOURCE' instead of staying 'test'"
fi

# An empty logs dir must not make the supervisor's periodic call fail.
rm -f "$LOGS"/*.log
if rotate_all; then
  ok "an empty logs directory is a no-op, not an error"
else
  bad "an empty logs directory is a no-op, not an error" "rotate_all returned non-zero"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
