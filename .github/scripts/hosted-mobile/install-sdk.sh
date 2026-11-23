#!/usr/bin/env bash
set -euo pipefail
umask 077

private="$RUNNER_TEMP/sdk-private"
phase=${1:-all}
case "$phase" in all|fetch|install) ;; *) exit 2 ;; esac
keep_download=false
trap '
  if [[ "$keep_download" == false ]]; then rm -rf "$private"; fi
  rm -f "$RUNNER_TEMP/sdk-recipient.key"
' EXIT
if [[ "$phase" != install ]]; then
  mkdir -m 700 "$private"
  url="$SDK_RELAY/keys/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$BENCHMARK_APP"
  for attempt in {1..180}; do
    if curl -fSs --max-time 8 "$url" -o "$private/wrapped" 2>/dev/null; then break; fi
    sleep 2
  done
  [[ -s "$private/wrapped" ]] || { echo 'The SDK relay did not authorize this runner'; exit 1; }
  openssl pkeyutl -decrypt -inkey "$RUNNER_TEMP/sdk-recipient.key" -in "$private/wrapped" \
    -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 > "$private/material"
  mapfile -t material < "$private/material"
  [[ ${material[0]} =~ ^[0-9a-f]{64}$ && ${material[1]} =~ ^[0-9a-f]{64}$ ]]
  printf '%s\n' "${material[0]}" > "$private/passphrase"
  if [[ -n "${EXACT_IOS_CACHE_MODE:-}" ]]; then
    install -m 600 "$private/passphrase" "$RUNNER_TEMP/ios-cache-passphrase"
  fi
  archive="$private/sdk.enc"
  if [[ -s "${EXACT_SDK_CIPHERTEXT:-}" ]]; then
    ln -s "$(realpath "$EXACT_SDK_CIPHERTEXT")" "$archive"
  fi
  mirror=
  if [[ ! -s "$archive" ]] && curl -fsS --max-time 10 "$SDK_RELAY/keys/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT.mirror" -o "$private/mirror.enc" 2>/dev/null; then
    mirror=$(openssl enc -d -aes-256-ctr -pbkdf2 -iter 100000 -pass "file:$private/passphrase" -in "$private/mirror.enc")
  fi
  case "$mirror" in
    https://release-assets.githubusercontent.com/*|https://objects.githubusercontent.com/*)
      curl -fsS --retry 4 --retry-all-errors --max-time 240 "$mirror" -o "$archive" || rm -f "$archive"
      ;;
  esac
  if [[ ! -s "$archive" ]]; then
    curl -fsS --retry 4 --retry-all-errors --max-time 20 "$SDK_RELAY/sdk-pieces.txt" -o "$private/pieces"
    test -s "$private/pieces"
    if grep -qvE '^part-[0-9]{3}$' "$private/pieces"; then exit 1; fi
    export sdk_pieces="$private"
    xargs -P 3 -n 1 bash -euc '
      curl -fsS --retry 4 --retry-all-errors --max-time 60 "$SDK_RELAY/pieces/$1" -o "$sdk_pieces/$1"
    ' bash < "$private/pieces"
    while IFS= read -r part; do cat "$private/$part"; done < "$private/pieces" > "$archive"
  fi
  printf '%s  %s\n' "${material[1]}" "$archive" | sha256sum -c -
  openssl enc -d -aes-256-ctr -pbkdf2 -iter 100000 -pass "file:$private/passphrase" -in "$archive" \
    | zstd -dc | tar --no-same-owner --warning=no-unknown-keyword -xf - -C "$private"
  rm -f "$private/sdk.enc" "$private/material" "$private/passphrase" "$RUNNER_TEMP/sdk-recipient.key"
fi
if [[ "$phase" == fetch ]]; then
  keep_download=true
  exit
fi
xtool --version
xtool sdk install "$private/darwin.xtoolsdk"
sdk_status=$(xtool sdk status)
printf '%s\n' "$sdk_status"
sdk=$(realpath "$(sed -n 's/^  Path: //p' <<< "$sdk_status")")
[[ -d "$sdk" ]]
# Pinned Exact expects the Swift SDK JSON that xTool 1 wrote. Point it at the
# corresponding files installed by xTool 2 without altering the compiler.
python3 - "$sdk" <<'PYTHON'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
developer = root / "Xcode.app/Contents/Developer"
resources = developer / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
assert (resources / "clang/lib/darwin/libclang_rt.ios.a").is_file()
target_triples = {}
for platform, target in (("iPhoneOS", "arm64-apple-ios"), ("MacOSX", "arm64-apple-macosx")):
    platform_developer = developer / "Platforms" / f"{platform}.platform" / "Developer"
    sdk_root = platform_developer / "SDKs" / f"{platform}.sdk"
    assert (sdk_root / "SDKSettings.json").is_file()
    server = platform_developer / "usr/bin/swift-plugin-server"
    server.parent.mkdir(parents=True, exist_ok=True)
    if not server.exists():
        server.symlink_to(root / "toolset/bin/OpenAppleMacrosServer")
    target_triples[target] = {
        "sdkRootPath": str(sdk_root.relative_to(root)),
        "swiftResourcesPath": str(resources.relative_to(root)),
        "swiftStaticResourcesPath": str(resources.with_name("swift_static").relative_to(root)),
        "includeSearchPaths": [str((platform_developer / "usr/lib").relative_to(root))],
        "librarySearchPaths": [str((platform_developer / "usr/lib").relative_to(root))],
        "toolsetPaths": ["toolset.json"],
    }
(root / "swift-sdk.json").write_text(json.dumps({"schemaVersion": "4.0", "targetTriples": target_triples}))
(root / "toolset.json").write_text(json.dumps({
    "schemaVersion": "1.0",
    "rootPath": "toolset/bin",
    "linker": {"path": "ld64.lld"},
    "librarian": {"path": "llvm-lib"},
    "swiftCompiler": {"extraCLIOptions": ["-Xfrontend", "-enable-cross-import-overlays", "-use-ld=lld"]},
}))
PYTHON
printf 'EXACT_APPLE_SDK=%s\n' "$sdk" >> "$GITHUB_ENV"
