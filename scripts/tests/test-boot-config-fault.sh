#!/bin/bash
# Regression harness for the boot-stage configuration-fault path.
#
#   bash scripts/tests/test-boot-config-fault.sh
#
# The same lesson as scripts/diagnose.sh, one layer earlier. console.sh learned
# to tell a crash from a setting the operator must change; the boot stages that
# run BEFORE it had not. prestart.sh calls die() — exit 1 — for a Funcom token
# that is missing or undecodable, Wings sees a non-zero exit, recreates the
# container, and the same unreadable token fails again. That is the first wall
# a new host hits, and it looks exactly like a crash.
#
# EX_CONFIG (78, sysexits.h) is the distinguished code that says "the input is
# wrong": the entrypoint holds on it instead of letting the loop run. Everything
# else keeps exiting as before, because a transient failure SHOULD be retried.

set -u

HERE="$(dirname "$(readlink -f "$0")")"
# NOT named SCRIPTS: lib.sh redefines that to "$BASE/scripts" when sourced
# below, and a harness whose paths are silently rewritten reports failures
# that have nothing to do with the code under test.
REPO_SCRIPTS="$(cd "$HERE/.." && pwd)"
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

export SOURCE="test"
# shellcheck source=/dev/null
source "$REPO_SCRIPTS/lib.sh" "$BASE"
# lib.sh turns on `set -eu` for whoever sources it, which would abort this
# harness on its first deliberate failure. Keep -u, drop -e: a test that dies
# at the first red line reports one failure and hides the rest.
set +e

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

stage() { # stage <file> <exit code>
  printf '#!/bin/bash\necho "stage ran"\nexit %s\n' "$2" > "$1"
  chmod +x "$1"
}

echo "boot config-fault path"

# --- the code itself ------------------------------------------------------

if [ "${EX_CONFIG:-}" = 78 ]; then
  ok "EX_CONFIG is sysexits' EX_CONFIG (78)"
else
  bad "EX_CONFIG is sysexits' EX_CONFIG (78)" "got '${EX_CONFIG:-unset}'"
fi

out=$(bash -c 'set -eu; SOURCE=t; source "$1" "$2"; die_config "token unreadable"' _ "$REPO_SCRIPTS/lib.sh" "$BASE" 2>&1)
rc=$?
if [ "$rc" = 78 ]; then ok "die_config exits 78"; else bad "die_config exits 78" "got $rc"; fi
case "$out" in
  *"token unreadable"*) ok "die_config keeps the operator's message" ;;
  *) bad "die_config keeps the operator's message" "got: $out" ;;
esac

# --- run_boot_stage -------------------------------------------------------

stage "$BASE/ok.sh" 0
if bash -c 'set -eu; SOURCE=t; source "$1" "$2"; run_boot_stage "$3" "$2"' _ "$REPO_SCRIPTS/lib.sh" "$BASE" "$BASE/ok.sh" >/dev/null 2>&1; then
  ok "a stage that succeeds is transparent"
else
  bad "a stage that succeeds is transparent" "run_boot_stage returned non-zero for exit 0"
fi

# A transient failure must STILL bring the container down: Wings recreating it
# is the right repair, and holding here would strand a server that would have
# recovered by itself.
stage "$BASE/broken.sh" 1
bash -c 'set -eu; SOURCE=t; source "$1" "$2"; run_boot_stage "$3" "$2"' _ "$REPO_SCRIPTS/lib.sh" "$BASE" "$BASE/broken.sh" >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ]; then ok "an ordinary failure still exits (Wings restarts)"; else bad "an ordinary failure still exits (Wings restarts)" "got $rc"; fi

# The one that matters: a configuration fault must NOT exit. It holds, so the
# panel keeps the explanation on screen instead of scrolling it away on the
# next boot.
log_out="$BASE/hold.out"
HOLD_REMINDER_INTERVAL=1 timeout 4 bash -c '
  set -eu; SOURCE=t; source "$1" "$2"; run_boot_stage "$3" "$2"' \
  _ "$REPO_SCRIPTS/lib.sh" "$BASE" "$BASE/config.sh" > "$log_out" 2>&1 &
holder=$!
stage "$BASE/config.sh" 78
wait $holder; rc=$?
# timeout kills it with 124: it was still alive, which is the whole point.
if [ "$rc" = 124 ]; then
  ok "a configuration fault holds instead of exiting"
else
  bad "a configuration fault holds instead of exiting" "process ended on its own with rc=$rc"
fi
if grep -q "HELD" "$log_out"; then
  ok "the hold says so on the console"
else
  bad "the hold says so on the console" "no HELD banner in: $(tr '\n' '|' < "$log_out")"
fi
if grep -q "config" "$log_out"; then
  ok "the hold names the stage that refused"
else
  bad "the hold names the stage that refused" "stage name missing from: $(tr '\n' '|' < "$log_out")"
fi

# --- wiring ---------------------------------------------------------------
#
# A static check, deliberately: reaching these lines for real needs a Funcom
# token, an extracted depot and the K8s ServiceAccount mount. What it pins is
# the intent — these four faults are the operator's to fix, and none of them
# improves by being restarted.

for pattern in \
  "Self-Host Service Token not set" \
  "couldn't decode HostId from JWT" \
  "extracted prerequisites missing" \
  'ServiceAccount mount $SA_DIR missing'
do
  line=$(grep -n "$pattern" "$REPO_SCRIPTS/prestart.sh" | head -1)
  case "$line" in
    *die_config*) ok "prestart: '$pattern' is a config fault" ;;
    "")           bad "prestart: '$pattern' is a config fault" "message no longer present — update this test with it" ;;
    *)            bad "prestart: '$pattern' is a config fault" "still plain die(): $line" ;;
  esac
done

# Postgres/schema failures are NOT config faults: they are the kind of thing a
# restart genuinely fixes, so they must keep exiting.
for pattern in "Postgres failed to start" "Database schema load failed"; do
  line=$(grep -n "$pattern" "$REPO_SCRIPTS/prestart.sh" | head -1)
  case "$line" in
    *die_config*) bad "prestart: '$pattern' stays retryable" "turned into a config fault: $line" ;;
    "")           bad "prestart: '$pattern' stays retryable" "message no longer present" ;;
    *)            ok "prestart: '$pattern' stays retryable" ;;
  esac
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
