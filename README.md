# Exact iOS on Linux

Travel Desk exercises Contacts and Calendar in an Exact app. This benchmark measures time from the start of an Ubuntu runner job through validation of an unsigned arm64 iPhone IPA.

The [benchmark workflow](.github/workflows/first-ios.yml) runs the same app with a shared Rust and Swift compiler bundle and from source. A missing or incompatible compiler bundle falls back to source. The compiler input pin lives in [pin.env](.github/actions/exact-setup/pin.env).

The workflow uses xTool 2, the pinned public Exact release inputs and compatible Darwin SDK material. The publisher supplies the SDK and optional compiler bundle through a private, one-time encrypted transfer. The source repository contains the test app and build scripts.

The workflow runs on demand using standard GitHub-hosted Ubuntu. Repository maintainers dispatch it against an authorized SDK relay. The same build phases also run in an Ubuntu container on a standalone Box.
