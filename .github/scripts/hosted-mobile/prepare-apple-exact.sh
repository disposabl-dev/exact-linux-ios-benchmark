#!/usr/bin/env bash
set -euo pipefail
cd "$EXACT"
platform=${1:-ios}
case "$platform" in
  ios) target=aarch64-apple-ios; options=(--device) ;;
  macos) target=aarch64-apple-darwin; options=() ;;
  *) exit 2 ;;
esac
phase=${2:-all}
case "$phase" in all|bootstrap|check) ;; *) exit 2 ;; esac
if [[ "$phase" != check ]]; then
  rustup target add "$target"
  cargo run --locked --manifest-path vendor/ibex/crates/hermes-lean-sys-installer/Cargo.toml -- --target "$target"
  cargo fetch --locked
fi
if [[ "$phase" != bootstrap ]]; then
  bun scripts/exact.mjs setup --check --platform "$platform" "${options[@]}"
fi
