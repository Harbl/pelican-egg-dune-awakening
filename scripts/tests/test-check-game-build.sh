#!/bin/bash
# Regression harness for scripts/check-game-build.sh.
#
#   bash scripts/tests/test-check-game-build.sh
#
# No SteamCMD, no network: the app-manifest and app_info fixtures below are
# trimmed copies of the real thing, taken from the 2026-09-17 Update 1.5
# incident (installed 24653560 vs published 25351779).
#
# The bias under test is silence. A check that cries wolf on every boot -- a
# failed lookup, an unreadable manifest -- trains the operator to skip the one
# line that mattered, so "not enough information" must print nothing at all.

set -u

HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/../check-game-build.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

eq() {
  local name=$1 got=$2 want=$3
  [ "$got" = "$want" ] && ok "$name" || bad "$name" "got '$got', want '$want'"
}

# --- fixtures -------------------------------------------------------------

cat > "$TMP/appmanifest_4754530.acf" <<'EOF'
"AppState"
{
	"appid"		"4754530"
	"name"		"Dune: Awakening Self-Hosted Server"
	"LastUpdated"		"1786631258"
	"buildid"		"24653560"
	"TargetBuildID"		"24653560"
}
EOF

cat > "$TMP/appmanifest_nobuild.acf" <<'EOF'
"AppState"
{
	"appid"		"4754530"
}
EOF

# Shape matters here: a non-public branch carrying its own buildid, and a
# depot entry carrying unrelated numbers. Anything that searches the document
# for "buildid" instead of walking to depots→branches→public picks one of
# these. Trimmed from the real 2026-09-17 response.
cat > "$TMP/app_info.json" <<'EOF'
{"data": {"4754530": {
  "common": {"name": "Dune: Awakening Self-Hosted Server"},
  "depots": {
    "4754531": {"manifests": {"public": {"gid": "1111111111111111111", "size": "4943927013"}}},
    "branches": {
      "internal": {"buildid": "99999999", "pwdrequired": "1"},
      "public":   {"buildid": "25351779", "timeupdated": "1789671657"}
    }
  }
}}}
EOF

# The same document for a DIFFERENT app: a PTC server must not read the
# retail branch because the response happened to contain one.
cat > "$TMP/app_info_otherapp.json" <<'EOF'
{"data": {"4754530": {"depots": {"branches": {"public": {"buildid": "25351779"}}}}}}
EOF

echo '{"data": {"4754530": {"common": {"name": "Dune"}}}}' > "$TMP/app_info_nobranches.json"
echo 'this is not json' > "$TMP/app_info_garbage.json"

echo "check-game-build.sh"

# --- manifest parsing -----------------------------------------------------

eq "reads the installed build id" \
  "$(manifest_buildid "$TMP/appmanifest_4754530.acf")" "24653560"

eq "missing manifest yields nothing" \
  "$(manifest_buildid "$TMP/does-not-exist.acf" || true)" ""

eq "manifest without a buildid yields nothing" \
  "$(manifest_buildid "$TMP/appmanifest_nobuild.acf" || true)" ""

# --- app_info parsing -----------------------------------------------------

eq "reads the public branch, not a depot or another branch" \
  "$(published_buildid_from_json 4754530 < "$TMP/app_info.json")" "25351779"

eq "a response for another app yields nothing" \
  "$(published_buildid_from_json 3104830 < "$TMP/app_info_otherapp.json" || true)" ""

eq "response without branches yields nothing" \
  "$(published_buildid_from_json 4754530 < "$TMP/app_info_nobranches.json" || true)" ""

eq "non-JSON response yields nothing" \
  "$(published_buildid_from_json 4754530 < "$TMP/app_info_garbage.json" || true)" ""

eq "empty response yields nothing" \
  "$(printf '' | published_buildid_from_json 4754530 || true)" ""

# --- verdict --------------------------------------------------------------

if report=$(build_drift_report "24653560" "25351779"); then
  case "$report" in
    *"installed here: 24653560"*) : ;;
    *) bad "behind: names the installed build" "got: $report"; false ;;
  esac && case "$report" in
    *"published now:  25351779"*) : ;;
    *) bad "behind: names the published build" "got: $report"; false ;;
  esac && case "$report" in
    *"M52"*) ok "behind: names both builds and the M52 symptom" ;;
    *) bad "behind: mentions M52" "got: $report" ;;
  esac
else
  bad "behind is reported" "build_drift_report returned 1 for a real drift"
fi

for pair in "25351779 25351779:same build" \
            " 25351779:installed unknown" \
            "24653560 :lookup failed" \
            " :both unknown"; do
  args=${pair%%:*}; label=${pair#*:}
  # stderr is captured too: a missing argument used to abort under `set -u`,
  # which returned non-zero for the wrong reason and still spat a shell error
  # into the console. Silence means silence on both streams.
  # shellcheck disable=SC2086
  if out=$(build_drift_report $args 2>&1); then
    bad "silent when $label" "printed: $(printf '%s' "$out" | tr '\n' '|')"
  else
    [ -z "${out:-}" ] && ok "silent when $label" \
      || bad "silent when $label" "returned 1 but printed: $(printf '%s' "$out" | tr '\n' '|')"
  fi
done

# The caller backgrounds this during boot under the entrypoint's shell; an
# unbound variable or a failing pipe there would land in the console mid-boot.
if bash -c '
    set -eu
    source "$1/../check-game-build.sh"
    manifest_buildid "$2" >/dev/null || true
    published_buildid_from_json 4754530 < "$3" >/dev/null || true
    build_drift_report >/dev/null || true
    exit 0
  ' _ "$HERE" "$TMP/does-not-exist.acf" "$TMP/app_info_nobranches.json" 2>/dev/null; then
  ok "survives the caller's set -eu"
else
  bad "survives the caller's set -eu" "a helper aborted a 'set -eu' shell"
fi

# Sourcing must not execute the check (the harness would then run SteamCMD).
if bash -c 'source "$1/../check-game-build.sh"; exit 0' _ "$HERE" >/dev/null 2>&1; then
  ok "sourcing runs nothing"
else
  bad "sourcing runs nothing" "sourcing the script had side effects"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
