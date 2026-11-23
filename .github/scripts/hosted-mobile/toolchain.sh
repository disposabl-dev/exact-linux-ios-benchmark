#!/usr/bin/env bash
set -euo pipefail

if [[ "${EXACT_PREINSTALLED_IOS_TOOLS:-}" == 1 && "$BENCHMARK_TARGET" == ios ]]; then
  swiftc --version
  llvm-lipo --version
  xtool --version
  rcodesign --version
  rustup target list --toolchain 1.99.1 --installed | grep -Fx aarch64-apple-ios
  exit
fi

system=()
if [[ "$(id -u)" != 0 ]]; then system=(sudo); fi

work="${EXACT_IOS_TOOL_DIR:-$RUNNER_TEMP/hosted-mobile-tools}"
mkdir -p "$work"
apt_options=(-o Acquire::Retries=2 -o Acquire::https::Timeout=25 -o Acquire::http::Timeout=25)
sources=/etc/apt/sources.list.d
if [[ "${EXACT_FAST_UBUNTU_MIRROR:-}" == 1 && -r "$sources/ubuntu.sources" ]]; then
  sources="$work/apt"
  mkdir -p "$sources"
  sed 's@^URIs: .*@URIs: https://mirrors.edge.kernel.org/ubuntu@' \
    /etc/apt/sources.list.d/ubuntu.sources > "$sources/ubuntu.sources"
  apt_options+=(-o Dir::Etc::sourcelist=/dev/null -o "Dir::Etc::sourceparts=$sources")
fi
apt() {
  "${system[@]}" env NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" "$@"
}
bootstrap=false
for tool in curl git jq python3 unzip zip zstd openssl gpg gcc make pkg-config; do
  command -v "$tool" >/dev/null || bootstrap=true
done
if [[ "$bootstrap" == true ]] || ! pkg-config --exists openssl; then
  echo "Refreshing package indexes"
  apt update -q
  apt install -y -qq --no-install-recommends \
    ca-certificates curl git jq python3 unzip zip zstd openssl gnupg build-essential pkg-config libssl-dev
fi
if ! command -v rustup >/dev/null; then
  apt install -y -qq --no-install-recommends rustup
  mkdir -p "$HOME/.cargo/bin"
  for tool in cargo rustc rustup; do ln -sf /usr/bin/rustup "$HOME/.cargo/bin/$tool"; done
  printf '%s\n' "$HOME/.cargo/bin" >> "$GITHUB_PATH"
fi

if [[ "$BENCHMARK_TARGET" != ios && "$BENCHMARK_TARGET" != macos ]]; then
  if ! command -v keytool >/dev/null; then
    apt install -y -qq --no-install-recommends openjdk-25-jdk-headless
    printf 'JAVA_HOME=%s\n' "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")" >> "$GITHUB_ENV"
  fi
  if [[ -z "${ANDROID_HOME:-}" ]]; then
    "${system[@]}" mkdir -p /usr/local/lib/android/sdk
    "${system[@]}" chown "$(id -u):$(id -g)" /usr/local/lib/android/sdk
    printf '%s\n' 'ANDROID_HOME=/usr/local/lib/android/sdk' 'ANDROID_SDK_ROOT=/usr/local/lib/android/sdk' >> "$GITHUB_ENV"
  fi
fi
if [[ "$BENCHMARK_TARGET" == android ]]; then exit 0; fi

if [[ ! -x /usr/lib/llvm-23/bin/llvm-lipo ]]; then
  curl -fsSL --retry 3 https://apt.llvm.org/llvm-snapshot.gpg.key -o "$work/llvm.asc"
  echo "8b2a587ffd672c4687e7581dad4b2f6c1bb2ad6b480cd9771ba2ff48e0b8c75d  $work/llvm.asc" | sha256sum -c -
  gpg --batch --dearmor -o "$work/llvm.gpg" "$work/llvm.asc"
  "${system[@]}" install -m 644 "$work/llvm.gpg" /usr/share/keyrings/exact-llvm.gpg
  echo 'deb [signed-by=/usr/share/keyrings/exact-llvm.gpg] https://apt.llvm.org/resolute/ llvm-toolchain-resolute-23 main' \
    | "${system[@]}" tee "$sources/exact-llvm.list" >/dev/null
  echo "Refreshing package indexes"
  apt update -q
  apt install -y -qq --no-install-recommends clang-23 lld-23 llvm-23
fi
printf '%s\n' /usr/lib/llvm-23/bin "$work" >> "$GITHUB_PATH"
if ! "$work/swift/usr/bin/swiftc" --version 2>/dev/null | grep -q '^Swift version 6\.4\.2 '; then
  echo "Installing Swift 6.4.2"
  url=https://download.swift.org/swift-6.4.2-release/ubuntu2604/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE-ubuntu26.04.tar.gz
  curl -fsSL --retry 3 "$url" -o "$work/swift.tar.gz"
  curl -fsSL --retry 3 "$url.sig" -o "$work/swift.tar.gz.sig"
  mkdir -m 700 "$work/swift-gpg"
  gpg --batch --homedir "$work/swift-gpg" --import "$(dirname "$0")/swift-6-release.asc"
  gpg --batch --homedir "$work/swift-gpg" --list-keys 52BB7E3DE28A71BE22EC05FFEF80A866B47A981F >/dev/null
  gpg --batch --homedir "$work/swift-gpg" --verify "$work/swift.tar.gz.sig" "$work/swift.tar.gz"
  mkdir "$work/swift"
  tar --no-same-owner -xzf "$work/swift.tar.gz" --strip-components=1 -C "$work/swift"
  rm "$work/swift.tar.gz"
fi
printf '%s\n' "$work/swift/usr/bin" >> "$GITHUB_PATH"

curl -fsSL --retry 3 https://github.com/xtool-org/xtool/releases/download/2.0.0-beta.1/xtool-x86_64.AppImage -o "$work/xtool"
echo "0361a2570e46a7734e8bafa71715ca8a72cf218e0e7a945eef0e4d71733b19e3  $work/xtool" | sha256sum -c -
chmod 755 "$work/xtool"
curl -fsSL --retry 3 https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/apple-codesign-0.29.0-x86_64-unknown-linux-musl.tar.gz -o "$work/rcodesign.tgz"
echo "dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002  $work/rcodesign.tgz" | sha256sum -c -
mkdir "$work/apple-codesign"
tar --no-same-owner -xzf "$work/rcodesign.tgz" --strip-components=1 -C "$work/apple-codesign"
install -m 755 "$(find "$work/apple-codesign" -name rcodesign -type f -print -quit)" "$work/rcodesign"
ln -sf /usr/lib/llvm-23/bin/llvm-lipo "$work/lipo"
printf '%s\n' 'APPIMAGE_EXTRACT_AND_RUN=1' 'EXACT_APPLE_LLVM_BIN=/usr/lib/llvm-23/bin' >> "$GITHUB_ENV"
