#!/usr/bin/env bash
set -euo pipefail

# Run inside the pinned Ubuntu buildpack container on a fresh standalone Box.
wall_start=$(date +%s)
cd "$(dirname "$0")/.."
export GITHUB_WORKSPACE="$PWD"
export HOME=/home/runner RUSTUP_HOME=/home/runner/.rustup CARGO_HOME=/home/runner/.cargo
export EXACT_IOS_TOOL_DIR=/home/runner/_work/_temp/hosted-mobile-tools
export RUNNER_OS=Linux RUNNER_ARCH=X64
export GITHUB_ENV="$RUNNER_TEMP/job.env" GITHUB_PATH="$RUNNER_TEMP/job.path" GITHUB_OUTPUT="$RUNNER_TEMP/job.out"
export GITHUB_RUN_ATTEMPT=1 BENCHMARK_APP=box-shared BENCHMARK_TARGET=ios
export EXACT_FEEDBACK=0 EXACT_FAST_UBUNTU_MIRROR=1
export EXACT_IOS_FAST_PREVIEW=true EXACT_IOS_PARALLEL_SETUP=true
export EXACT_IOS_COMPILER_DIR="$HOME/.cache/exact-native/ios-linux"
export PATH="$HOME/.cargo/bin:$PATH"
[[ ! -e "$EXACT_IOS_COMPILER_DIR" ]]
mkdir -p "$HOME/.cargo/bin"
git config --global --add safe.directory "$GITHUB_WORKSPACE"
touch "$GITHUB_ENV" "$GITHUB_PATH" "$GITHUB_OUTPUT"

if [[ -n "${SDK_RELAY:-}" ]]; then
  : "${GITHUB_RUN_ID:?Expected a unique benchmark ID}"
  [[ "$SDK_RELAY" == https://* ]]
  export EXACT_IOS_CACHE_PROBE=true EXACT_IOS_CACHE_MODE=restore EXACT_IOS_SWIFT_CACHE=true
  mkdir -p "$HOME/.config/xtool" /root/.config
  ln -s "$HOME/.config/xtool" /root/.config/xtool
  trap 'rm -f "$RUNNER_TEMP/sdk-recipient.key" "$RUNNER_TEMP/ios-cache-passphrase"' EXIT
  (
    umask 077
    openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$RUNNER_TEMP/sdk-recipient.key"
    openssl pkey -in "$RUNNER_TEMP/sdk-recipient.key" -pubout -out "$RUNNER_TEMP/sdk-recipient.pub"
    chmod 644 "$RUNNER_TEMP/sdk-recipient.pub"
  )
fi

sed -i 's@^URIs: .*@URIs: https://mirrors.edge.kernel.org/ubuntu@' /etc/apt/sources.list.d/ubuntu.sources
apt=(apt-get -o Acquire::Retries=2 -o Acquire::https::Timeout=25 -o Acquire::Languages=none)
"${apt[@]}" update -q
DEBIAN_FRONTEND=noninteractive "${apt[@]}" install -y -qq --no-install-recommends \
  jq python3 zip zstd pkg-config libncurses6 rustup nodejs
for tool in cargo rustc rustup; do ln -s /usr/bin/rustup "$HOME/.cargo/bin/$tool"; done

curl -fsSL --retry 3 https://github.com/oven-sh/bun/releases/download/bun-v1.4.5/bun-linux-x64.zip -o "$RUNNER_TEMP/bun.zip"
echo "94559b3b528995a49452f9f2404cec74f2efd7d06e0a000a8cd214b02c3666eb  $RUNNER_TEMP/bun.zip" | sha256sum -c -
unzip -p "$RUNNER_TEMP/bun.zip" bun-linux-x64/bun > /usr/local/bin/bun
chmod 755 /usr/local/bin/bun
rm "$RUNNER_TEMP/bun.zip"
export EXACT_IOS_CACHE_DIGEST="$(sed -n 's/^ios-cas-cache-digest=//p' .github/actions/exact-setup/pin.env)"

apply_job_environment() {
  local name value dir
  while IFS='=' read -r name value; do export "$name=$value"; done < "$GITHUB_ENV"
  while IFS= read -r dir; do export PATH="$dir:$PATH"; done < "$GITHUB_PATH"
  : > "$GITHUB_ENV"
  : > "$GITHUB_PATH"
}

bash scripts/benchmark.sh restore
apply_job_environment
if [[ -n "${SDK_RELAY:-}" ]]; then
  bash scripts/benchmark.sh setup
  apply_job_environment
  bash .github/scripts/hosted-mobile/install-sdk.sh install
else
  bash scripts/benchmark.sh public-tools
  apply_job_environment
  bash .github/scripts/hosted-mobile/install-public-sdk.sh
fi
apply_job_environment
bash scripts/benchmark.sh validate
apply_job_environment
if [[ -n "${SDK_RELAY:-}" ]]; then
  bash scripts/benchmark.sh activate
  apply_job_environment
fi
cd "$NATIVE_APP_DIR"
EXACT="$HOME/work/_temp/exact-sdk" bash "$GITHUB_WORKSPACE/.github/scripts/hosted-mobile/build-ios.sh"
printf 'Box benchmark from container start to verified IPA: %ss\n' "$(( $(date +%s) - wall_start ))"
