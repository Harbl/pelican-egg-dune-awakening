#!/bin/bash
# Regression harness for scripts/diagnose.sh.
#
#   bash scripts/tests/test-diagnose.sh
#
# No battlegroup, no network: every case is a fixture log written to a temp
# dir. The fixtures are verbatim excerpts from the 2026-09-17 incident (an
# eight-hour restart loop caused by Funcom's Update 1.5 refusing a display
# name), so the signatures stay pinned to text FLS actually emits.
#
# The asymmetry that matters: a missed signature costs the operator a worse
# error message, while a false positive holds a server that would have
# recovered by itself. The transient cases below are the ones guarding that.

set -u

HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/../diagnose.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

# expect_unrecoverable <name> <service> <logfile> [substring that must appear]
expect_unrecoverable() {
  local name=$1 svc=$2 file=$3 needle=${4:-}
  local out rc
  out=$(diagnose_fatal "$svc" "$file") && rc=0 || rc=$?
  if [ "$rc" != 0 ]; then
    bad "$name" "expected unrecoverable (rc=0), got rc=$rc"
    return
  fi
  if [ -n "$needle" ] && [[ "$out" != *"$needle"* ]]; then
    bad "$name" "output missing '$needle'; got: $(printf '%s' "$out" | tr '\n' '|')"
    return
  fi
  ok "$name"
}

# expect_no_diagnosis <name> <service> <logfile>
expect_no_diagnosis() {
  local name=$1 svc=$2 file=$3
  local out rc
  out=$(diagnose_fatal "$svc" "$file") && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    bad "$name" "expected no diagnosis (rc=1), got rc=0 with: $(printf '%s' "$out" | tr '\n' '|')"
    return
  fi
  ok "$name"
}

# --- fixtures -------------------------------------------------------------

# Verbatim from the reporter's logs/gateway.log, token elided.
cat > "$TMP/gateway-display-name.log" <<'EOF'
[2026-09-17 19:26:47,416][root] INFO: Sending Request:
FlsHostUrl: https://sb-retail.fls.funcom.com/
ServiceAuthToken: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.<elided>
Request: api/GatewayDeclareFarmStatus {
  "DatacenterId": "Europe",
  "BattlegroupId": "sh-955b27440521047f-wqekxn",
  "IsActive": true,
  "DisplayName": "[ENG|PvE/P] RagingAverageJoes [Welcome Kit: TWheel,100k & more]",
  "Revision": -1
}
[2026-09-17 19:26:47,768][root] ERROR: Request error api/GatewayDeclareFarmStatus with code 500: {"ErrorCode":400003,"Code":400,"Status":"Bad Request","Error":"INVALID_ARGUMENT","ErrorMessage":"Error in DeclareFarmStatusAsync: Invalid input provided - Invalid display name - [ENG|PvE/P] RagingAverageJoes [Welcome Kit: TWheel,100k & more] in sh-955b27440521047f-wqekxn"}
[2026-09-17 19:26:47,769][root] WARNING: Attempt 7/10 of 'matchmaker request' failed, retrying after 75.68 seconds: HTTP Error 500: Internal Server Error
EOF

# Same class, a field we have no named remedy for.
cat > "$TMP/gateway-other-argument.log" <<'EOF'
[2026-09-17 19:26:47,768][root] ERROR: Request error api/GatewayDeclareFarmStatus with code 500: {"ErrorCode":400003,"Code":400,"Status":"Bad Request","Error":"INVALID_ARGUMENT","ErrorMessage":"Error in DeclareFarmStatusAsync: Invalid input provided - Invalid region - Atlantis in sh-955b27440521047f-wqekxn"}
EOF

# Transient: Funcom unreachable. A restart genuinely can fix this.
cat > "$TMP/gateway-transient.log" <<'EOF'
[2026-09-17 19:26:47,416][root] INFO: Sending Request:
[2026-09-17 19:26:47,768][root] ERROR: Request error api/GatewayDeclareFarmStatus with code 502: Bad Gateway
[2026-09-17 19:26:47,769][root] WARNING: Attempt 3/10 of 'matchmaker request' failed, retrying after 7.50 seconds: <urlopen error [Errno -3] Temporary failure in name resolution>
EOF

: > "$TMP/gateway-empty.log"

# The signature scrolled out of the tail window: stay silent rather than
# claim a fault from stale text.
{
  echo '[old] ERROR: {"Error":"INVALID_ARGUMENT","ErrorMessage":"Invalid display name - x in y"}'
  for i in $(seq 1 60); do echo "[2026-09-17 19:30:00,000][root] INFO: heartbeat $i"; done
} > "$TMP/gateway-scrolled.log"

# Two different refusals in one window: the operator needs the current one.
cat > "$TMP/gateway-two-errors.log" <<'EOF'
[2026-09-17 18:00:00,000][root] ERROR: {"Error":"INVALID_ARGUMENT","ErrorMessage":"Error in DeclareFarmStatusAsync: Invalid input provided - Invalid region - Atlantis in sh-x"}
[2026-09-17 19:00:00,000][root] ERROR: {"Error":"INVALID_ARGUMENT","ErrorMessage":"Error in DeclareFarmStatusAsync: Invalid input provided - Invalid display name - LATEST NAME in sh-x"}
EOF

# --- cases ----------------------------------------------------------------

echo "diagnose.sh"

expect_unrecoverable "rejected display name is named as such" \
  gateway "$TMP/gateway-display-name.log" "DUNE_WORLD_TITLE"

expect_unrecoverable "rejected display name quotes what FLS said" \
  gateway "$TMP/gateway-display-name.log" "Invalid display name - [ENG|PvE/P] RagingAverageJoes"

expect_unrecoverable "other INVALID_ARGUMENT still holds" \
  gateway "$TMP/gateway-other-argument.log" "Invalid region - Atlantis"

expect_no_diagnosis "transient FLS outage is not a config fault" \
  gateway "$TMP/gateway-transient.log"

expect_no_diagnosis "empty log yields nothing" \
  gateway "$TMP/gateway-empty.log"

expect_no_diagnosis "missing log yields nothing" \
  gateway "$TMP/gateway-does-not-exist.log"

expect_no_diagnosis "a service with no signatures yields nothing" \
  director "$TMP/gateway-display-name.log"

DIAGNOSE_TAIL_LINES=40 \
expect_no_diagnosis "signature outside the tail window is ignored" \
  gateway "$TMP/gateway-scrolled.log"

expect_unrecoverable "the most recent refusal wins" \
  gateway "$TMP/gateway-two-errors.log" "LATEST NAME"

# console.sh runs under `set -eu`, where a command substitution that exits
# non-zero takes the whole script with it. A diagnose function that tripped
# that would kill the supervisor mid-diagnosis -- a worse outage than the one
# it was reporting. Exercise the three shapes under the caller's own flags.
strict_ok=1
for fixture in gateway-display-name gateway-transient does-not-exist; do
  bash -c '
    set -eu
    source "$1/../diagnose.sh"
    diagnose_fatal gateway "$2" >/dev/null || true
    exit 0
  ' _ "$HERE" "$TMP/$fixture.log" 2>/dev/null || strict_ok=0
done
if [ "$strict_ok" = 1 ]; then
  ok "survives the caller's set -eu"
else
  bad "survives the caller's set -eu" "diagnose_fatal aborted a 'set -eu' shell"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
