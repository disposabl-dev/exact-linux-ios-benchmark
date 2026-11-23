#!/usr/bin/env bash
set -euo pipefail

start=$(date +%s)
export EXACT_UPDATE_GENESIS=1 EXACT_UPDATE_TRUST=production
dir="${EXACT_IOS_ARTIFACT_DIR:-$RUNNER_TEMP/verified-ios}"
export EXACT_BAKE_OUTPUT="$dir/bake"
export CARGO_TARGET_DIR="${EXACT_IOS_COMPILER_DIR:-$RUNNER_TEMP/ios-target}"
unset CARGO_PROFILE_RELEASE_LTO CARGO_PROFILE_RELEASE_CODEGEN_UNITS CARGO_PROFILE_BALANCED_LTO CARGO_PROFILE_BALANCED_CODEGEN_UNITS CARGO_PROFILE_SIZE_LTO
if [[ "${EXACT_IOS_FAST_PREVIEW:-}" == true ]]; then
  export CARGO_PROFILE_BALANCED_LTO=off CARGO_PROFILE_BALANCED_CODEGEN_UNITS=16
fi
ipa="$dir/apps.ipa"
mkdir -p "$(dirname "$ipa")"
if [[ "${EXACT_IOS_CACHE_PROBE:-}" == true ]]; then
  if [[ "${GITHUB_REF_NAME:-}" == *-ios-cache-sticky-read ]]; then
    export CARGO_LOG=cargo::core::compiler::fingerprint=info
  fi
  export IOS_REAL_CARGO=$(command -v cargo)
  export IOS_EVIDENCE_PUBLIC_SEED=1 IOS_EVIDENCE_DIR="$dir/cargo-evidence"
  mkdir -p "$dir/capture-bin"
  ln -s "$GITHUB_WORKSPACE/.github/actions/exact-setup/scripts/ios-cargo-capture.sh" "$dir/capture-bin/cargo"
  if [[ "${EXACT_IOS_SWIFT_CACHE:-}" == true ]]; then
    export IOS_REAL_SWIFT=$(command -v swift)
    ln -s "$GITHUB_WORKSPACE/.github/scripts/hosted-mobile/swift-compile-cache.sh" "$dir/capture-bin/swift"
  fi
  export PATH="$dir/capture-bin:$PATH"
fi
archive=(bun exact.mjs ios --device --release --unsigned --no-install --archive "$ipa")
if [[ "${EXACT_IOS_CACHE_RESTORED:-false}" == true ]]; then
  if ! "${archive[@]}"; then
    echo 'Build with restored compiler outputs failed. Retrying once from source.'
    test "$CARGO_TARGET_DIR" = "$HOME/.cache/exact-native/ios-linux"
    rm -rf -- "$CARGO_TARGET_DIR" "$EXACT_BAKE_OUTPUT" "$dir/cargo-evidence"
    rm -f -- "$ipa"
    "${archive[@]}"
  fi
else
  "${archive[@]}"
fi
if [[ "${EXACT_IOS_CACHE_PROBE:-}" == true ]]; then
  first_capture=$(ls -1tr "$IOS_EVIDENCE_DIR"/cargo-ios.* | sed -n '1p')
  jq -rs 'map(select(.reason == "compiler-artifact")) | "First Cargo archive units reused: \(map(select(.fresh == true)) | length)/\(length)"' "$first_capture"
fi
unzip -tq "$ipa"
unpacked=$(mktemp -d "$RUNNER_TEMP/ipa.XXXXXX")
trap 'rm -rf "$unpacked"' EXIT
unzip -q "$ipa" -d "$unpacked"
apps=("$unpacked"/Payload/*.app)
[[ ${#apps[@]} == 1 && -f "${apps[0]}/Info.plist" ]]
[[ -z "$(find "$unpacked" -name embedded.mobileprovision -print -quit)" ]]
id=$(jq -er '.app.id' app.json)
exe=$(python3 - "${apps[0]}/Info.plist" "$id" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as file:
    info = plistlib.load(file)
if info["CFBundleIdentifier"] != sys.argv[2]:
    raise SystemExit("IPA bundle identifier does not match the app")
keys = (
    "NSContactsUsageDescription",
    "NSCalendarsFullAccessUsageDescription",
    "NSCalendarsWriteOnlyAccessUsageDescription",
)
if any(not info.get(key) for key in keys):
    raise SystemExit("IPA is missing the Contacts or Calendar purpose strings")
print(info["CFBundleExecutable"])
PY
)
[[ "$exe" != */* && "$exe" != . && "$exe" != .. ]]
"$EXACT_APPLE_LLVM_BIN/llvm-lipo" "${apps[0]}/$exe" -verify_arch arm64
"$EXACT_APPLE_LLVM_BIN/llvm-objdump" --macho --private-headers "${apps[0]}/$exe" > "$unpacked/load-commands"
grep -Ein '^[[:space:]]*platform[[:space:]]+(ios|2)[[:space:]]*$' "$unpacked/load-commands"
rcodesign print-signature-info --config-file /dev/null "${apps[0]}/$exe" > "$unpacked/signature"
grep -q 'CodeSignatureFlags(.*ADHOC' "$unpacked/signature"
grep -Eq '^[[:space:]]*cms: null[[:space:]]*$' "$unpacked/signature"
echo "Verified Contacts, Calendar full-access, and Calendar write-only descriptions"
sha256sum "$ipa"
printf 'Verified unsigned arm64 iPhone IPA in %ss\n' "$(( $(date +%s) - start ))"
