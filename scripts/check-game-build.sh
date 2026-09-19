#!/bin/bash
# check-game-build.sh BASE_DIR
#
# Compare the Funcom depot build this server has installed against the one
# Steam currently publishes, and say so in the console when they differ.
#
# Advisory only. It reads two numbers and prints; it never touches the game
# files, never fails the boot, and never updates anything. Updating is the
# panel's Reinstall, which is deliberate: pulling 5 GB of new binaries under a
# server that is already running would swap the code out from under live
# players, and a boot-time download would turn every restart into a gamble on
# Funcom's CDN.
#
# Why it exists
# -------------
# The egg downloads the depot at INSTALL time only, so a deployment stays on
# the build it was installed with until someone reinstalls. Nothing told the
# operator they had fallen behind. On 2026-09-17 Funcom shipped Update 1.5
# (build 25351779); a reporter's server stayed on 24653560, and the first
# sign was players hitting "M52 Outdated Client" — a client-side error code
# that points at the player's machine, not at the server that actually
# needed updating. The revision the server advertises to FLS (2064155 vs
# 2111270) is what the client refuses, and neither number is visible anywhere
# an operator looks.
#
# Sourcing this file defines the helpers without running anything, so
# scripts/tests/test-check-game-build.sh can exercise the parsing and the
# verdict against fixtures with no SteamCMD and no network.

# --------------------------------------------------------------------------
# Pure helpers
# --------------------------------------------------------------------------

# Read the installed build id out of a SteamCMD app manifest (VDF):
#   "buildid"		"24653560"
# Empty output if the file or key is missing; callers treat that as "unknown".
manifest_buildid() {
  local manifest=$1
  [ -r "$manifest" ] || return 1
  grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$manifest" \
    | head -n 1 \
    | grep -oE '[0-9]+"$' \
    | tr -d '"'
}

# Read the public branch's build id out of a SteamCMD-info JSON document:
#   {"data": {"<appid>": {"depots": {"branches": {"public": {"buildid": "…"}}}}}}
#
# Strict about where it looks. Other branches (PTC, internal betas) carry their
# own buildid and depot entries carry unrelated numbers, so a document-wide
# search for "buildid" would happily return the wrong one.
#
# Why an HTTP lookup and not the SteamCMD this egg already ships: that binary
# is 32-bit, and the runtime image carries no lib32 (the installer apt-installs
# lib32gcc-s1 and libcurl4:i386 into the *install* image only). Running it here
# fails with "required file not found". Valve publishes no first-party endpoint
# for a branch's build id -- which is why third-party SteamCMD mirrors exist --
# so this check depends on one, treats any failure as silence, and can be
# pointed elsewhere or switched off with DUNE_BUILD_CHECK_URL.
published_buildid_from_json() {
  local appid=$1
  python3 -c '
import json, sys
appid = sys.argv[1]
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(1)
app = (doc.get("data") or {}).get(appid) or {}
branch = ((app.get("depots") or {}).get("branches") or {}).get("public") or {}
build = str(branch.get("buildid") or "")
if not build.isdigit():
    sys.exit(1)
print(build)
' "$appid" 2>/dev/null
}

# Compose the operator-facing verdict.
#   $1 installed build id ("" when unknown)
#   $2 published build id ("" when the lookup failed)
# stdout: the lines to print, already worded for the console
# return 0: this server is BEHIND — the caller should print loudly
# return 1: up to date, or not enough information to claim anything
build_drift_report() {
  # Defaulted, not positional: an unknown build is the normal case here (no
  # manifest, no network), and under the caller's `set -u` a bare $1 would
  # abort the boot shell rather than report "nothing to say".
  local installed=${1:-} published=${2:-}

  # Silence beats a guess. An operator who is told "could not check" on every
  # boot learns to ignore the line, and then misses the one that mattered.
  [ -n "$installed" ] || return 1
  [ -n "$published" ] || return 1
  [ "$installed" = "$published" ] && return 1

  echo "──────────────────────────────────────────────────────────────"
  echo "A newer Funcom server build is published."
  echo "    installed here: $installed"
  echo "    published now:  $published"
  echo "Players whose client already updated will be refused with"
  echo "\"M52 Outdated Client\" until this server runs the same build —"
  echo "the error names the client, but it is the server that is behind."
  echo "FIX: Reinstall this server in the panel, then Start it."
  echo "     World data under server/state/ and the admin configs in"
  echo "     data/admin/ survive a Reinstall; no egg re-import needed."
  echo "──────────────────────────────────────────────────────────────"
  return 0
}

# --------------------------------------------------------------------------
# Execution
# --------------------------------------------------------------------------

main() {
  BASE="${1:-${DUNE_BASE_DIR:-}}"
  export SOURCE="build-check"
  source "$(dirname "$(readlink -f "$0")")/lib.sh" "$BASE"

  local appid="${SRCDS_APPID:-4754530}"
  local manifest="$BASE/server/steamapps/appmanifest_${appid}.acf"
  local url="${DUNE_BUILD_CHECK_URL:-https://api.steamcmd.net/v1/info/APPID}"
  local installed published report

  installed=$(manifest_buildid "$manifest") || installed=""
  if [ -z "$installed" ]; then
    log "installed build unknown (no $manifest) — skipping the update check"
    return 0
  fi

  # An operator who does not want this server reaching a third party on boot
  # sets DUNE_BUILD_CHECK_URL=off and loses only the warning.
  if [ "$url" = "off" ]; then
    log "update check disabled (DUNE_BUILD_CHECK_URL=off) — installed build $installed"
    return 0
  fi
  url="${url//APPID/$appid}"

  published=$(curl -fsSL --max-time "${BUILD_CHECK_TIMEOUT:-20}" "$url" 2>/dev/null \
    | published_buildid_from_json "$appid") || published=""

  if [ -z "$published" ]; then
    # The lookup service, DNS, or egress — none of them are this server's
    # problem, and none of them justify alarming the operator.
    log "could not look up the published build — skipping (installed $installed)"
    return 0
  fi

  if report=$(build_drift_report "$installed" "$published"); then
    while IFS= read -r line; do warn "$line"; done <<< "$report"
  else
    log "game build is current ($installed)"
  fi

  # Leave the answer somewhere the panel can read it later without re-running
  # SteamCMD. Best effort: a failed write must not turn an advisory check into
  # a boot error.
  printf '{"installed":"%s","published":"%s","behind":%s,"checked_at":"%s"}\n' \
    "$installed" "$published" \
    "$([ "$installed" = "$published" ] && echo false || echo true)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STATE/build-check.json" 2>/dev/null || true
}

# Sourced by the test harness: define the helpers, run nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
