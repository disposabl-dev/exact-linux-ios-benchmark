#!/usr/bin/env bash
# Fetch content-addressed inputs from the canonical release on a fresh runner.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
platform=$SETUP_PLATFORM
# Keep the actual checkout at the publisher path in runner containers.
if [[ $platform == ios-linux ]]; then export EXACT="$HOME/work/_temp/exact-sdk"; fi
app_checkout=${EXACT_APP_CHECKOUT:-$GITHUB_WORKSPACE}
ref=$SETUP_EXACT_REF
tag="v${SETUP_BUNDLE_VERSION}-exact-${ref}-bun-$SETUP_BUN_VERSION"
release="https://github.com/disposabl-dev/disposabl-exact/releases/download/$tag"
manifest="$scripts/../inputs.json"
if [[ $SETUP_BUNDLE_VERSION -ge 9 ]]; then manifest="$scripts/../inputs-v${SETUP_BUNDLE_VERSION}.json"; fi
staging=$(mktemp -d "$RUNNER_TEMP/exact-inputs.XXXXXX")
trap 'rm -rf "$staging"' EXIT
if [[ $SETUP_BUNDLE_VERSION -ge 11 ]]; then
  manifest="$staging/inputs.json"
  python3 "$scripts/release-manifest.py" \
    "$SETUP_BUNDLE_VERSION" "$ref" "$SETUP_BUN_VERSION" "$manifest"
fi
publisher=".cache/exact/publisher/$ref"
cache="$RUNNER_TEMP/exact-bundles"
cargo_target="$HOME/.cache/exact-native/cargo"
ios_tools="$RUNNER_TEMP/exact-ios-inputs"
mkdir -p "$cache" "$EXACT"
asset() {
  python3 "$scripts/fetch-input.py" "$release" "$manifest" "$1" "$2"
}
extract() {
  local name=$1 directory=$2 file=$3
  shift 3
  asset "$name" "$file" || return 1
  mkdir -p "$directory" || return 1
  zstd -dc "$file" | tar --no-same-owner -xf - -C "$directory" "$@"
}
has_asset() {
  python3 -c 'import json,sys; sys.exit(sys.argv[2] not in json.load(open(sys.argv[1])))' "$manifest" "$1"
}
source_tree() {
  extract sdk.tar.zst "$EXACT" "$staging/sdk.tar.zst"
  [[ $(git -C "$EXACT" rev-parse HEAD) == "$ref" ]]
  git -C "$EXACT" reset --hard --quiet HEAD
  (cd "$EXACT" && bun install --frozen-lockfile)
}
source_tree &
pids=($!)
bundle_platform=$platform
if [[ $platform == ios-linux ]]; then bundle_platform=web; fi
bundle="exact-$ref-$bundle_platform-$RUNNER_OS-$RUNNER_ARCH-bun-$SETUP_BUN_VERSION.tar.zst"
source_kind=release
if [[ -f "$cache/$bundle" ]]; then source_kind=cache; fi
extract "$bundle" "$HOME" "$cache/$bundle" &
pids+=($!)
case "$platform" in
  android)
    extract cargo-android.zst "$cargo_target" "$staging/cargo.zst" & pids+=($!)
    extract cargo-gradle.zst "$HOME/.gradle" "$staging/gradle.zst" & pids+=($!)
    web="exact-$ref-web-Linux-X64-bun-$SETUP_BUN_VERSION.tar.zst"
    extract "$web" "$HOME" "$staging/publisher.zst" "$publisher" & pids+=($!)
    ;;
  ios)
    mkdir -p "$ios_tools"
    extract cargo-ios.zst "$cargo_target" "$staging/cargo.zst" & pids+=($!)
    if has_asset ios-link-kit.zst; then
      extract ios-link-kit.zst "$ios_tools/link" "$staging/link.zst" & pids+=($!)
    fi
    if has_asset ios-host-catalog.zst; then
      (extract ios-host-catalog.zst "$ios_tools/host-catalog" "$staging/host-catalog.zst" || { rm -rf "$ios_tools/host-catalog"; echo 'Host catalog unavailable; using stock or normal build.'; }) & pids+=($!)
    fi
    for file in ios-source-times.json ios-baker.json; do
      asset "$file" "$ios_tools/$file" & pids+=($!)
    done
    ;;
  web|ios-linux) ;;
  *) exit 2 ;;
esac
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
[[ $status == 0 ]] || exit 1
[[ -x "$HOME/$publisher/exact-bake" && -x "$HOME/$publisher/exact-js-bake" ]]
echo "EXACT_PUBLISH_TOOLS=$HOME/$publisher" >> "$GITHUB_ENV"
echo "source=$source_kind" >> "$GITHUB_OUTPUT"
if [[ $platform == ios ]]; then
  if [[ -d /Applications/Xcode_27.2.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
    echo "DEVELOPER_DIR=$DEVELOPER_DIR" >> "$GITHUB_ENV"
  fi
  bun "$scripts/ios-baker.mjs" enable "$ios_tools/ios-baker.json"
  if [[ -d "$ios_tools/link" ]]; then
    bash "$scripts/ios-link-kit-enable.sh"
  fi
  if [[ -f "$ios_tools/link/arms/manifest.json" ]] && ! python3 "$scripts/ios-link-arms.py" restore --kit "$ios_tools/link" --target "$cargo_target"; then
    echo 'Using the standard Apple framework build for this runner.'
  fi
  # Exact chooses entries by the current package sources, dependencies and compiler flags.
  if [[ -d "$ios_tools/link/packages-kept" ]]; then
    package_root="$cargo_target/apple-swift/ios-17.0-balanced"
    mkdir -p "$package_root"
    cp -R "$ios_tools/link/packages-kept" "$package_root/"
  fi
  # Match the canonical public SDK checkout used by Cargo build scripts.
  (cd "$EXACT" && git ls-files -z | xargs -0 touch -t 202001010000)
  find "$EXACT" -type d -not -path '*/.git*' -exec touch -t 202001010000 {} +
  {
    if [[ -d "$ios_tools/link" ]]; then
      if [[ -f "$ios_tools/host-catalog/manifest.json" ]]; then
        echo "EXACT_HOST_CATALOG=$ios_tools/host-catalog"
        echo "EXACT_LINK_KIT_PROOF=$scripts/ios-host-select.py"
      else
        echo "EXACT_LINK_KIT_PROOF=$scripts/ios-link-kit.py"
      fi
      echo "EXACT_LINK_KIT=$ios_tools/link"
    fi
    echo "EXACT_IOS_SOURCE_TIMES=$ios_tools/ios-source-times.json"
  } >> "$GITHUB_ENV"
elif [[ $platform == ios-linux ]]; then
  # Select the Contacts state wrapper on Linux, where the SDK SwiftUI macro is unavailable.
  git -C "$EXACT" apply "$scripts/ios-contacts-compat.patch"
  # The verified Linux web bundle already ships the same Exact host baker.
  bun "$scripts/ios-baker.mjs" patch
  baker="$HOME/$publisher/exact-js-bake"
  printf 'EXACT_IOS_BAKER_PATH=%s\nEXACT_IOS_BAKER_SHA256=%s\n' \
    "$baker" "$(sha256sum "$baker" | cut -d ' ' -f 1)" >> "$GITHUB_ENV"
  if [[ "${EXACT_IOS_PARALLEL_SETUP:-}" != true ]]; then
    bash "$GITHUB_WORKSPACE/.github/scripts/hosted-mobile/prepare-apple-exact.sh"
  fi
elif [[ $platform == android ]]; then
  # Resolve the pinned host plugins while Exact bakes and compiles Rust. Keep
  # Gradle's project state separate from the real app and its dependency locks.
  (
    prime="$RUNNER_TEMP/gradle-prime"
    cp -R "$EXACT/host/android" "$prime"
    metadata="$app_checkout/apps/apps/gradle-verification.xml"
    if [[ -f "$metadata" ]]; then cp "$metadata" "$prime/gradle/verification-metadata.xml"; fi
    cd "$prime"
    exec ./gradlew --offline --daemon --no-watch-fs --dependency-verification=strict help
  ) > "$RUNNER_TEMP/gradle-prime.log" 2>&1 < /dev/null &
  bash "$scripts/android-fast-profile.sh"
  echo 'org.gradle.caching=true' >> "$HOME/.gradle/gradle.properties"
  if [[ ! -f "$ANDROID_HOME/ndk/27.3.13750724/source.properties" || ! -f "$ANDROID_HOME/platforms/android-37.2/source.properties" || ! -f "$ANDROID_HOME/build-tools/37.0.0/source.properties" ]]; then
    sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
    if [[ ! -x "$sdkmanager" ]]; then sdkmanager=$(command -v sdkmanager); fi
    (set +o pipefail; yes | "$sdkmanager" --licenses >/dev/null)
    "$sdkmanager" --install 'platforms;android-37.2' 'build-tools;37.0.0' 'ndk;27.3.13750724'
  fi
  echo "ANDROID_NDK_HOME=$ANDROID_HOME/ndk/27.3.13750724" >> "$GITHUB_ENV"
  echo "ANDROID_BUILD_TOOLS_VERSION=37.0.0" >> "$GITHUB_ENV"
fi
if [[ $platform != web ]]; then
  app="$HOME/exact-native/apps/apps"
  git -C "$app_checkout" worktree add --quiet --detach "$HOME/exact-native" HEAD
  mkdir -p "$app/.exact"
  ln -s "$EXACT" "$app/.exact/checkout"
  (cd "$app" && bun install --frozen-lockfile)
  {
    echo "NATIVE_APP_DIR=$app"
    echo "CARGO_TARGET_DIR=$cargo_target"
    echo 'CARGO_PROFILE_RELEASE_LTO=off'
    echo 'CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16'
    echo 'CARGO_PROFILE_BALANCED_LTO=off'
    echo 'CARGO_PROFILE_SIZE_LTO=off'
  } >> "$GITHUB_ENV"
fi
