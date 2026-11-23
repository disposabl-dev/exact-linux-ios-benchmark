#!/usr/bin/env bash
set -euo pipefail
export CARGO_TARGET_DIR
CARGO_TARGET_DIR=$(mktemp -d "$RUNNER_TEMP/cargo-mac.XXXXXX")
previous=''
for phase in cold edited; do
  if [[ "$phase" == edited ]]; then
    python3 - <<'PY'
from pathlib import Path
file = Path("app.contract")
source = file.read_text()
heading = 'text "Travel Desk" role="heading"'
assert source.count(heading) == 1
file.write_text(source.replace(heading, 'text "Travel Desk preview" role="heading"'))
PY
  fi
  start=$SECONDS
  bun exact.mjs mac --release --json > "$RUNNER_TEMP/mac-result.json"
  elapsed=$(( SECONDS - start ))
  bundle=$(jq -er '.path' "$RUNNER_TEMP/mac-result.json")
  binary=$(python3 - "$bundle" <<'PY'
from pathlib import Path
import plistlib
import sys

contents = Path(sys.argv[1]) / "Contents"
plist = plistlib.loads((contents / "Info.plist").read_bytes())
assert plist["CFBundleIdentifier"] == "dev.disposabl.fresh.traveldesk"
print(contents / "MacOS" / plist["CFBundleExecutable"])
PY
  )
  if [[ "$RUNNER_OS" == macOS ]]; then
    xcrun lipo -verify_arch arm64 "$binary"
    xcrun vtool -show-build "$binary" > "$RUNNER_TEMP/mac-build-version"
    codesign --verify --deep --strict "$bundle"
  else
    llvm-lipo "$binary" -verify_arch arm64
    llvm-objdump --macho --private-headers "$binary" > "$RUNNER_TEMP/mac-build-version"
    rcodesign print-signature-info --config-file /dev/null "$binary" > "$RUNNER_TEMP/mac-signature"
    grep -q 'CodeSignatureFlags(.*ADHOC' "$RUNNER_TEMP/mac-signature"
    grep -Eq '^[[:space:]]*cms: null[[:space:]]*$' "$RUNNER_TEMP/mac-signature"
  fi
  grep -Eiq '^[[:space:]]*platform[[:space:]]+(macos|1)[[:space:]]*$' "$RUNNER_TEMP/mac-build-version"
  hash=$(shasum -a 256 "$binary" | cut -d ' ' -f1)
  [[ "$hash" != "$previous" ]]
  previous=$hash
  printf 'Verified %s desktop build in %ss (%s).\n' "$phase" "$elapsed" "$hash" | tee -a "$GITHUB_STEP_SUMMARY"
done
