# Exact iOS on Linux

Travel Desk exercises Contacts and Calendar in an Exact app. This benchmark measures time from the start of an Ubuntu runner job through validation of an unsigned arm64 iPhone IPA.

## SDK delivery on Ubuntu

The [Ubuntu SDK workflow](.github/workflows/ubuntu-sdk.yml) builds Travel Desk on
GitHub Actions and Blacksmith without an Apple login, a signing identity, or a
relay. It verifies the SHA-256 of the published iPhoneOS 27.1 archive and uses
the toolset from xTool 2.0.0-beta.1. The versioned [Exact pin](.github/actions/exact-setup/pin.env)
also controls the prebuilt Exact host tools. This workflow compiles the app
dependencies on each fresh runner.

The archive comes from the [Apple inputs project](https://github.com/kemono-games/apple-inputs),
which publishes its Xcode export and checksum. The iPhone-only adapter uses the
same linker and macros as xTool 2. It supports the iPhone device target.

[scripts/box.sh](scripts/box.sh) uses the same SDK adapter by default in the
`buildpack-deps:26.04` image at digest
`sha256:194c70abaf37ac12f2aadca115308af03f90cbf60c1ffbd3afc4a7a451f65368`.
Give it the checked-out source and a writable `RUNNER_TEMP`. It verifies
the IPA and reports elapsed time.

## Compiler cache benchmark

The [benchmark workflow](.github/workflows/first-ios.yml) runs the same app with a shared Rust and Swift compiler bundle and from source. A missing or incompatible compiler bundle falls back to source. The compiler input pin lives in [pin.env](.github/actions/exact-setup/pin.env).

The workflow uses xTool 2, the pinned public Exact release inputs and compatible Darwin SDK material. The publisher supplies the SDK and optional compiler bundle through a private, one-time encrypted transfer. The source repository contains the test app and build scripts.

The workflow runs on demand using standard GitHub-hosted Ubuntu. Repository maintainers dispatch it against an authorized SDK relay. The same build phases also run in an Ubuntu container on a standalone Box.

For a standalone run, invoke [scripts/box.sh](scripts/box.sh) in the `buildpack-deps:26.04` image at digest `sha256:194c70abaf37ac12f2aadca115308af03f90cbf60c1ffbd3afc4a7a451f65368`. Pass a writable `RUNNER_TEMP`, the authorized `SDK_RELAY` and a unique `GITHUB_RUN_ID`. The operator authorizes `sdk-recipient.pub` from that run, and the script reports the IPA verification and elapsed time.

On a Box with slow downloads, the operator can mount previously fetched encrypted input files and set `EXACT_SDK_CIPHERTEXT` and `EXACT_COMPILER_ARCHIVE` to their container paths. The same digest checks and one-time authorization apply.

The [public GitHub Actions run](https://github.com/disposabl-dev/exact-linux-ios-benchmark/actions/runs/45169244903) verifies the IPA on both compiler paths.
