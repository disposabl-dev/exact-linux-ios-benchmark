#!/usr/bin/env bash
# PATH wrapper for an isolated public seed build. It preserves Cargo stdout and
# separately records the real compiler messages needed to reconstruct evidence.
set -euo pipefail
: "${IOS_REAL_CARGO:?}" "${IOS_EVIDENCE_DIR:?}"
[[ "${IOS_EVIDENCE_PUBLIC_SEED:-}" == 1 ]] || { echo 'Cargo evidence capture requires a public synthetic seed' >&2; exit 1; }
[[ "$IOS_REAL_CARGO" == /* && -x "$IOS_REAL_CARGO" && "$IOS_EVIDENCE_DIR" == /* ]] || { echo 'Invalid Cargo capture paths' >&2; exit 1; }
# Only the root cargo rustc reports the linked iOS archive and all its build
# dependencies. Other commands (metadata, host baker, Swift's module builds)
# keep their unmodified output and are not compiler evidence for that archive.
if [[ "${1:-}" != rustc ]]; then exec "$IOS_REAL_CARGO" "$@"; fi
json=0 target=0
for arg in "$@"; do
  [[ "$arg" != --message-format=json* ]] || json=1
  [[ "$arg" != aarch64-apple-ios ]] || target=1
done
if (( !json || !target )); then exec "$IOS_REAL_CARGO" "$@"; fi
mkdir -p "$IOS_EVIDENCE_DIR"
file=$(mktemp "$IOS_EVIDENCE_DIR/cargo-ios.XXXXXXXX")
# Preserve Cargo's exit code and byte stream even when it fails. A consumer
# must reject partial captures lacking a matching compiler-artifact message.
"$IOS_REAL_CARGO" "$@" | tee "$file"
