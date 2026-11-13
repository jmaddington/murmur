#!/bin/zsh
# End-to-end: real pipeline + mock remote providers + screenshots.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=${1:-build/e2e}
rm -rf "$OUT"; mkdir -p "$OUT"
./scripts/build.sh >/dev/null || exit 1
(cd core && cargo test --release --quiet 2>&1 | grep "test result") || exit 1

python3 tests/e2e/mock_server.py 8765 & MOCK=$!
trap "kill $MOCK 2>/dev/null" EXIT
sleep 0.5
MURMUR_E2E_MOCK_BASE=http://127.0.0.1:8765/v1 \
  OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" build/Murmur.app/Contents/MacOS/Murmur --e2e --out "$OUT" --cases tests/e2e/cases.json --screenshots \
  > "$OUT/stdout.json" 2> >(tee "$OUT/log.txt" >&2)
STATUS=$?
echo "report: $OUT/report.json  screenshots: $OUT/screenshots"
exit $STATUS
