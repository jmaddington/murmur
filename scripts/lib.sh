# Shared helpers for build/package scripts. Source with: source "${0:A:h}/lib.sh"

# step "label" cmd args…  — run a command quietly; on failure print its output
# and, on GitHub Actions, raise a (public) annotation with the last lines so
# failures are diagnosable without access to the job logs.
step() {
  local label=$1; shift
  local out
  if ! out=$("$@" 2>&1); then
    print -r -- "$out"
    annotate error "$label failed" "$(print -r -- "$out" | tail -25)"
    return 1
  fi
  [[ -n "${VERBOSE:-}" ]] && print -r -- "$out"
  return 0
}

# annotate level title message — GitHub Actions workflow command (no-op locally).
annotate() {
  [[ -z "${GITHUB_ACTIONS:-}" ]] && return 0
  local msg=${3//'%'/'%25'}
  msg=${msg//$'\r'/'%0D'}
  msg=${msg//$'\n'/'%0A'}
  print -r -- "::$1 title=$2::$msg"
}

# notarize FILE — submit, wait, staple; on rejection annotate Apple's issue log.
notarize() {
  local f=$1 out id status
  out=$(xcrun notarytool submit "$f" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
        --wait --timeout 30m --output-format json 2>&1) || true
  id=$(print -r -- "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
  status=$(print -r -- "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null)
  print "  notarization ${id:-?}: ${status:-unknown}"
  if [[ "$status" != "Accepted" ]]; then
    local log=""
    [[ -n "$id" ]] && log=$(xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" 2>&1 | tail -40)
    print -r -- "$out"; print -r -- "$log"
    annotate error "Notarization of ${f:t} ${status:-failed}" "$out
$log"
    return 1
  fi
  step "Stapling ${f:t}" xcrun stapler staple "$f"
}
