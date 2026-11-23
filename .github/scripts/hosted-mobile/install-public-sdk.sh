#!/usr/bin/env bash
# Adapt the versioned device SDK and xTool 2's toolset to Exact's Swift SDK interface.
set -euo pipefail
work=$(mktemp -d "${RUNNER_TEMP:?}/apple-inputs.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
sdk="$RUNNER_TEMP/exact-darwin-27.1"
platform="$sdk/Developer/Platforms/iPhoneOS.platform/Developer"
device="$platform/SDKs/iPhoneOS27.1.sdk"
resources="$sdk/swift"
tools="$sdk/toolset"

extract() {
  local url=$1 digest=$2 destination=$3 archive="$work/input.tar.gz"
  shift 3
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 180 "$url" -o "$archive"
  printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
  tar --no-same-owner -xzf "$archive" -C "$destination" "$@"
}
mkdir -p "$platform/SDKs" "$platform/usr/bin" "$platform/usr/lib/swift/host" \
  "$resources/clang/lib" "$tools" "$work/macros"
extract https://github.com/kemono-games/apple-inputs/releases/download/ios-27.1-xcode-27.1-27A9275-r1/apple-inputs.tar.gz \
  58de6c3bbd8d94a89e0c08d038eaa8208191085d74e2ff542107a86cf1098e46 "$work" iphoneos darwin
mv "$work/iphoneos" "$device"
mv "$work/darwin" "$resources/clang/lib/darwin"
ln -s "$device/usr/lib/swift" "$resources/iphoneos"
test -r "$device/usr/lib/swift/shims/module.modulemap"
resource_path=$(swiftc -print-target-info | jq -er '.paths.runtimeResourcePath')
ln -s "$resource_path/clang/include" "$resources/clang/include"

extract https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/v1.1.0/toolset-x86_64.tar.gz \
  a5166f2d56ac45707e5ef2f3c20a41a94af8ef0c0456354224dd08656e874188 "$tools"
mv "$tools/bin/libtool" "$tools/bin/llvm-lib"
extract https://github.com/xtool-org/OpenAppleMacros/releases/download/v1.4.1/OpenAppleMacrosServer-x86_64.tar.gz \
  2d80c922d0873dd8b0a85e19d10bd7f42a1aea3db3a85f7b6edf56fe9b687a21 "$work/macros"
mv "$work/macros/OpenAppleMacrosServer" "$tools/bin/"
mkdir "$tools/plugins"
jq -er '.plugins[]' "$work/macros/info.json" | while read -r library; do
  [[ "$library" =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]]
  touch "$tools/plugins/lib$library.so"
done
ln -s "$tools/bin/OpenAppleMacrosServer" "$platform/usr/bin/swift-plugin-server"
ln -s "$tools/plugins" "$platform/usr/lib/swift/host/plugins"

jq -n --arg path "${device#"$sdk/"}" '{
  schemaVersion:"4.0",
  targetTriples:{"arm64-apple-ios":{sdkRootPath:$path, swiftResourcesPath:"swift", toolsetPaths:["toolset.json"]}}
}' > "$sdk/swift-sdk.json"
jq -n '{
  schemaVersion:"1.0", rootPath:"toolset/bin", linker:{path:"ld64.lld"}, librarian:{path:"llvm-lib"},
  swiftCompiler:{extraCLIOptions:["-Xfrontend","-enable-cross-import-overlays","-use-ld=lld"]}
}' > "$sdk/toolset.json"

jq -e '.Version == "27.1"' "$device/SDKSettings.json" >/dev/null
test -r "$resources/clang/lib/darwin/libclang_rt.ios.a"
xtool --version
printf 'EXACT_APPLE_SDK=%s\n' "$sdk" >> "${GITHUB_ENV:?}"
echo 'Verified iPhoneOS SDK 27.1 from the pinned public input'
