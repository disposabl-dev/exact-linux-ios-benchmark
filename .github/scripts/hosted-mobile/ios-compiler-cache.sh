#!/usr/bin/env bash
set -euo pipefail
mode=$1
bundle=$2
: "${EXACT:?}" "${EXACT_IOS_COMPILER_DIR:?}"
target="$EXACT_IOS_COMPILER_DIR"
staged="$target.pending"
key() {
  : "${EXACT_APPLE_SDK:?}"
  {
    git -C "$EXACT" rev-parse HEAD
    printf '%s\n' "$EXACT" "$target" "$EXACT_APPLE_SDK" "${CARGO_HOME:-$HOME/.cargo}" \
      "${EXACT_IOS_FAST_PREVIEW:-false}" "$(command -v swiftc)" "$(command -v clang)"
    if [[ "${EXACT_IOS_SWIFT_CACHE:-}" == true ]]; then echo swift-local-cas-v1; fi
    rustc +1.99.1 -vV
    swiftc --version
    clang --version
    xtool --version
    sha256sum "$EXACT_APPLE_SDK/swift-sdk.json" "$EXACT_APPLE_SDK/toolset.json"
  } | sha256sum | cut -d ' ' -f 1
}
activate() {
  [[ ! -e "$target" && -d "$staged" ]]
  if [[ "$(cat "$bundle/compiler-key")" != "$(key)" ]]; then
    printf 'Compiler cache key mismatch with Swift %s and Clang %s\n' "$(command -v swiftc)" "$(command -v clang)" >&2
    return 1
  fi
  mv "$staged" "$target"
}
case "$mode" in
  pack)
    [[ ! -e "$bundle" && -d "$target/apple-swift" ]]
    mkdir -p "$bundle"
    key > "$bundle/compiler-key"
    paths=()
    for path in balanced x86_64-unknown-linux-gnu aarch64-apple-ios apple-swift apple-modules swift-cas; do
      [[ ! -d "$target/$path" ]] || paths+=("$path")
    done
    # The seed has already removed its app crate, executables and receipts.
    # Do not publish a raw Apple SDK, and keep the compiler cache encrypted.
    tar --exclude='*.sdk' --exclude='Xcode.app' --exclude='incremental' \
      --exclude='*.p12' --exclude='*.linked' -cf - -C "$target" "${paths[@]}" \
      | zstd -T0 -1 | openssl enc -aes-256-ctr -pbkdf2 -iter 100000 \
          -pass "file:$RUNNER_TEMP/ios-cache-passphrase" -out "$bundle/compiler.tar.zst.enc"
    (cd "$bundle" && sha256sum compiler.tar.zst.enc compiler-key > SHA256SUMS)
    du -sh "$bundle"
    ;;
  activate)
    activate
    ;;
  stage|restore)
    : "${EXACT_IOS_CACHE_DIGEST:?Use a pinned compiler cache archive digest}"
    private=$(mktemp -d "$RUNNER_TEMP/compiler-transfer.XXXXXX")
    trap 'rm -rf "$private"' EXIT
    if [[ -s "${EXACT_COMPILER_ARCHIVE:-}" ]]; then
      archive="$EXACT_COMPILER_ARCHIVE"
    else
      archive="$private/compiler.zip"
      for attempt in {1..30}; do
        if [[ -s "$RUNNER_TEMP/ios-cache-passphrase" ]] &&
           curl -fSs --max-time 8 "$SDK_RELAY/keys/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT.compiler" -o "$private/url.enc" 2>/dev/null; then
          url=$(openssl enc -d -aes-256-ctr -pbkdf2 -iter 100000 \
            -pass "file:$RUNNER_TEMP/ios-cache-passphrase" -in "$private/url.enc")
          case "$url" in
            https://*.blob.core.windows.net/*|https://*.actions.githubusercontent.com/*|https://release-assets.githubusercontent.com/*) ;;
            *) echo 'Unexpected compiler cache download host' >&2; exit 1 ;;
          esac
          if curl -fSsL --max-time 240 "$url" -o "$archive"; then break; fi
          rm -f "$archive"
        fi
        sleep 2
      done
    fi
    [[ -s "$archive" ]]
    printf '%s  %s\n' "$EXACT_IOS_CACHE_DIGEST" "$archive" | sha256sum -c -
    [[ ! -e "$target" && ! -e "$staged" ]]
    mkdir -p "$bundle" "$staged"
    keep_staged=false
    trap '
      if [[ "$keep_staged" == false ]]; then rm -rf "$staged"; fi
      rm -rf "$private"
    ' EXIT
    unzip -p "$archive" compiler-key > "$bundle/compiler-key"
    # The pinned ZIP digest authenticates its header and the entire encrypted entry.
    excludes=()
    if [[ "${EXACT_REBUILD_SWIFT_GRAPH:-false}" == true ]]; then
      excludes=(--exclude=apple-swift --exclude=apple-modules)
    fi
    unzip -p "$archive" compiler.tar.zst.enc \
      | openssl enc -d -aes-256-ctr -pbkdf2 -iter 100000 \
          -pass "file:$RUNNER_TEMP/ios-cache-passphrase" \
      | zstd -dc | tar --no-same-owner "${excludes[@]}" -xf - -C "$staged"
    if [[ "${EXACT_REBUILD_SWIFT_GRAPH:-false}" == true ]]; then
      [[ -d "$staged/swift-cas" && ! -e "$staged/apple-swift" && ! -e "$staged/apple-modules" ]]
      echo 'Restored compiler outputs with a fresh SwiftPM build graph'
    fi
    if [[ "$mode" == stage ]]; then
      keep_staged=true
      exit
    fi
    activate
    ;;
  *) exit 2 ;;
esac
