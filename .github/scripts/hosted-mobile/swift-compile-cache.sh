#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == build ]]; then
  set -- "$@" -Xswiftc -explicit-module-build -Xswiftc -cache-compile-job \
    -Xswiftc -cas-path -Xswiftc "$CARGO_TARGET_DIR/swift-cas" -Xswiftc -Rcache-compile-job
  if [[ "${IOS_PRIME_PUBLIC_CAPABILITIES:-}" == true ]]; then
    args=("$@")
    for ((i = 1; i + 1 < ${#args[@]}; i++)); do
      if [[ "${args[i]}" == --target && "${args[i+1]}" == ExactKit ]]; then
        args[i+1]=ExactComposition
        echo 'Priming the public iOS capability targets' >&2
        EXACT_APPLE_LINK=all "$IOS_REAL_SWIFT" "${args[@]}" >&2
        break
      fi
    done
  fi
fi
exec "$IOS_REAL_SWIFT" "$@"
