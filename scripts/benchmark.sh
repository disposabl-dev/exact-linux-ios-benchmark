#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export EXACT="$HOME/work/_temp/exact-sdk"
scripts=.github/scripts/hosted-mobile
pin() { sed -n "s/^$1=//p" .github/actions/exact-setup/pin.env; }

case "${1:?expected a benchmark phase}" in
  restore)
    export SETUP_PLATFORM=ios-linux
    export SETUP_EXACT_REF="$(pin exact-ref)"
    export SETUP_BUN_VERSION="$(pin bun-version)"
    export SETUP_BUNDLE_VERSION="$(pin bundle-version)"
    exec bash .github/actions/exact-setup/scripts/restore.sh
    ;;
  setup)
    scripts=.github/scripts/hosted-mobile
    pids=()
    bash "$scripts/install-sdk.sh" fetch & sdk_pid=$!
    if [[ -n "$EXACT_IOS_CACHE_DIGEST" && "$BENCHMARK_APP" == *-shared ]]; then
      (
        bash "$scripts/ios-compiler-cache.sh" stage "$RUNNER_TEMP/prebuilt-ios" ||
          echo 'Shared compiler bundle unavailable. The build will compile dependencies.'
      ) & pids+=("$!")
    fi
    bash "$scripts/toolchain.sh" & tools_pid=$!
    bash "$scripts/prepare-apple-exact.sh" ios bootstrap & pids+=("$!")
    status=0
    wait "$sdk_pid" || status=$?
    wait "$tools_pid" || status=$?
    if [[ $status == 0 && "${EXACT_IOS_FAST_SDK_INSTALL:-false}" == true ]]; then
      PATH="$EXACT_IOS_TOOL_DIR:$PATH" APPIMAGE_EXTRACT_AND_RUN=1 \
        bash "$scripts/install-sdk.sh" install || status=$?
    fi
    for pid in "${pids[@]}"; do wait "$pid" || status=$?; done
    exit "$status"
    ;;
  validate)
    bash .github/actions/exact-setup/scripts/setup-linux-ios.sh
    export PATH="$EXACT_APPLE_LLVM_BIN:$PATH"
    bash .github/scripts/hosted-mobile/prepare-apple-exact.sh ios check
    git -C "$EXACT" ls-files -z | (cd "$EXACT" && xargs -0 touch -h -t 202001010000)
    find "$EXACT" -type d -not -path '*/.git*' -exec touch -h -t 202001010000 {} +
    find "${CARGO_HOME:-$HOME/.cargo}/hermes-lean-sys" -exec touch -h -t 202001010000 {} +
    ;;
  activate)
    bundle="$RUNNER_TEMP/prebuilt-ios"
    if [[ -f "$bundle/compiler-key" ]] &&
       EXACT="$HOME/work/_temp/exact-sdk" bash .github/scripts/hosted-mobile/ios-compiler-cache.sh activate "$bundle"; then
      echo 'EXACT_IOS_CACHE_RESTORED=true' >> "$GITHUB_ENV"
    else
      echo 'Building from source. There is no compatible shared compiler bundle.'
    fi
    ;;
  *) exit 2 ;;
esac
