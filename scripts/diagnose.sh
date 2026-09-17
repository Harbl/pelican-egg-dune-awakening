#!/bin/bash
# diagnose.sh - turn a dead service's log tail into an operator-actionable cause.
#
# Sourced by console.sh. Every function here is pure text analysis over a log
# file: no side effects, no service state, no network. That is deliberate, so
# scripts/tests/test-diagnose.sh can exercise the signatures against fixture
# logs without a running battlegroup.
#
# Why this file exists
# --------------------
# The supervisor in console.sh had exactly one failure vocabulary: bail out and
# let Wings recreate the container. That is right for a transient fault and
# wrong for an operator misconfiguration, because recreating the container
# replays the same rejected input forever. On 2026-09-17 a reporter's server
# restart-looped every ~10m30 for eight hours: Funcom's Update 1.5 tightened
# the display-name validation in FLS, GatewayDeclareFarmStatus started coming
# back INVALID_ARGUMENT, the gateway exhausted its ten retries (~9m25 of
# doubling backoff), console.sh saw a dead critical service and exited 3 -- and
# the panel showed only "see logs/gateway.log". The cause was one panel
# variable away the whole time.
#
# Contract:
#   diagnose_fatal <service> <logfile>
#     stdout : explanation lines, already indented for the caller
#     return 0: the fault is UNRECOVERABLE -- an operator must change a setting;
#               restarting cannot fix it, so the caller must not restart-loop
#     return 1: no known signature -- the caller keeps its default behaviour
#
# Adding a signature: match only on text the upstream component actually
# emitted, never on our own inference. A false "unrecoverable" holds a server
# that would have recovered on its own, which is worse than the loop.

# Number of trailing log lines considered. The gateway prints the full request
# payload before each attempt, so its failures span dozens of lines apiece.
DIAGNOSE_TAIL_LINES="${DIAGNOSE_TAIL_LINES:-400}"

# Pull the last ErrorMessage out of one of FLS's JSON error bodies. FLS answers
# a rejected declaration with, on a single line:
#   {"ErrorCode":400003,"Code":400,"Status":"Bad Request",
#    "Error":"INVALID_ARGUMENT","ErrorMessage":"Error in DeclareFarmStatusAsync:
#    Invalid input provided - Invalid display name - <name> in <battlegroup>"}
# Empty output when absent; callers fall back to their own wording.
fls_error_message() {
  printf '%s\n' "$1" \
    | grep -o '"ErrorMessage":"[^"]*"' \
    | tail -n 1 \
    | sed 's/^"ErrorMessage":"//; s/"$//'
}

# The gateway is the only component that talks to Funcom's account plane, so it
# is where an operator's bad input surfaces as a third-party refusal rather
# than as a local error.
diagnose_gateway() {
  local recent=$1 msg
  msg=$(fls_error_message "$recent")

  case "$recent" in
    *'Invalid display name'*)
      echo "CAUSE: Funcom's FLS refused the name this server advertises, so the"
      echo "       gateway could never register the battlegroup and gave up"
      echo "       after its retries."
      echo "       FLS said: ${msg:-Invalid display name}"
      echo "FIX:   change DUNE_WORLD_TITLE in the panel's Startup tab, then"
      echo "       restart. FLS validates this string on their side and"
      echo "       tightened the rule in Update 1.5 (2026-09-17); plain letters,"
      echo "       digits and spaces are known to pass. Restarting without"
      echo "       changing it just replays the same refusal."
      return 0
      ;;
    *'"Error":"INVALID_ARGUMENT"'*)
      # Same class, different field: FLS named our input as the problem, we
      # just do not have a specific remedy for that field yet. Still
      # unrecoverable -- a restart resends the identical payload.
      echo "CAUSE: Funcom's FLS rejected a value this server declared."
      echo "       FLS said: ${msg:-INVALID_ARGUMENT (no message)}"
      echo "FIX:   correct the matching setting in the panel's Startup tab,"
      echo "       then restart. The value is refused on Funcom's side, so"
      echo "       restarting unchanged will repeat this exactly."
      return 0
      ;;
  esac

  return 1
}

diagnose_fatal() {
  local svc=$1 logfile=$2 recent
  [ -r "$logfile" ] || return 1
  recent=$(tail -n "$DIAGNOSE_TAIL_LINES" "$logfile" 2>/dev/null) || return 1
  [ -n "$recent" ] || return 1

  case "$svc" in
    gateway) diagnose_gateway "$recent" ;;
    *)       return 1 ;;
  esac
}
