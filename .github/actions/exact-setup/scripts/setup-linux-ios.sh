#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${EXACT_XCODE_XIP:-} ]]; then
  APPIMAGE_EXTRACT_AND_RUN=1 xtool sdk install --slim "$EXACT_XCODE_XIP"
fi
swiftpm=${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/swiftpm}
sdk=${EXACT_APPLE_SDK:-${swiftpm:-$HOME/.swiftpm}/swift-sdks/darwin.artifactbundle}
if [[ ! -r "$sdk/swift-sdk.json" ]]; then
  echo '::error::This runner has no Darwin Swift SDK installed by xTool.'
  exit 1
fi
llvm=${EXACT_APPLE_LLVM_BIN:-/usr/lib/llvm-23/bin}
for tool in swiftc rcodesign zip "$llvm/llvm-lipo" "$llvm/llvm-objdump"; do
  if ! command -v "$tool" >/dev/null; then
    echo "::error::Missing Linux iOS tool $tool"
    exit 1
  fi
done
printf '%s\n' "$llvm" >> "$GITHUB_PATH"
printf 'EXACT_APPLE_SDK=%s\nEXACT_APPLE_LLVM_BIN=%s\n' "$sdk" "$llvm" >> "$GITHUB_ENV"
