#!/bin/bash
# rotate-logs.sh BASE_DIR
#
# Bound the size of everything under $LOGS. Called at boot and periodically by
# console.sh's supervisor loop; safe to run by hand at any time.
#
# Why this exists
# ---------------
# Nothing ever trimmed these files. A test server that had been up for months
# held a 10 GB director.log and a 1.3 GB text-router.log; a reporter's
# production server, 8.9 GB. The Director writes that much at its DEFAULT
# level=info — every ServerState and every settings update is logged as a full
# JSON payload, ~15 KB a line, and it does it on an EMPTY server. Lowering the
# level is the operator's call (director_config.ini, level=), not something to
# force on them: those lines are exactly what past incidents were diagnosed
# from. Bounding the files is not.
#
# Policy: a log over MAX is cut down to its last KEEP bytes. Keeping the tail
# rather than deleting outright is deliberate — the recent end is the half an
# operator needs, and a log that vanishes mid-incident is its own outage.
#
# Truncation, not renaming: every writer opened its file with O_APPEND (see
# launch_bg in lib.sh), so writes always land at the current end of file and a
# truncate-in-place is picked up immediately. Renaming would leave each daemon
# writing to an unlinked inode until it restarts — the disk would never come
# back and the visible log would stay empty.

BASE="${1:-${DUNE_BASE_DIR:-}}"
# Only claim the log tag when run standalone. console.sh sources this file, and
# an unconditional export would retag every later line the supervisor prints as
# if the rotator had written it.
: "${SOURCE:=rotate-logs}"
export SOURCE
# BASH_SOURCE, not $0: this file is sourced by console.sh and by the test
# harness, where $0 is the caller and would resolve lib.sh to the wrong place.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh" "$BASE"

# Thresholds in MB. Defaults bound a busy battlegroup to a couple of GB across
# all services while leaving each log with a useful window of history.
LOG_MAX_MB="${DUNE_LOG_MAX_MB:-200}"
LOG_KEEP_MB="${DUNE_LOG_KEEP_MB:-50}"

# rotate_one <file> — trim one log if it is over the cap.
# Returns 0 when it trimmed, 1 when it left the file alone.
rotate_one() {
  local f=$1 max_b keep_b size
  max_b=$(( LOG_MAX_MB * 1024 * 1024 ))
  keep_b=$(( LOG_KEEP_MB * 1024 * 1024 ))
  [ -f "$f" ] || return 1
  size=$(stat -c %s "$f" 2>/dev/null) || return 1
  [ "$size" -gt "$max_b" ] || return 1

  # Keep the tail via a temp file in the same directory (same filesystem, so
  # no cross-device copy), then write it back over the original.
  #
  # The window between truncating and refilling is a few milliseconds during
  # which a concurrent append can be interleaved or lost. That is an accepted
  # cost for a log file: the alternative (rename + signal every daemon to
  # reopen) needs cooperation these binaries do not offer, and losing a line of
  # ServerState spam is not worth a boot-time dance.
  local tmp="$f.rotating.$$"
  if ! tail -c "$keep_b" "$f" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    warn "could not read the tail of $(basename "$f") — left untouched"
    return 1
  fi
  {
    printf '=== log trimmed by rotate-logs.sh at %s — %s MB dropped, last %s MB kept ===\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(( (size - keep_b) / 1024 / 1024 ))" "$LOG_KEEP_MB"
    cat "$tmp"
  } > "$f" 2>/dev/null || {
    rm -f "$tmp"
    warn "could not rewrite $(basename "$f") — left as is"
    return 1
  }
  rm -f "$tmp"
  log "trimmed $(basename "$f"): $(( size / 1024 / 1024 )) MB -> ${LOG_KEEP_MB} MB"
  return 0
}

# rotate_all — sweep every *.log under $LOGS. Never fails the caller: this runs
# inside the supervisor loop, where an error must not take the server down.
rotate_all() {
  local f trimmed=0
  [ -d "$LOGS" ] || return 0
  for f in "$LOGS"/*.log; do
    [ -e "$f" ] || continue
    rotate_one "$f" && trimmed=$((trimmed + 1))
  done
  [ "$trimmed" -gt 0 ] && log "rotation pass complete: $trimmed file(s) trimmed"
  return 0
}

# Sourced by the test harness and by console.sh: define, run nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rotate_all
fi
