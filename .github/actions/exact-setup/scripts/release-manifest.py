#!/usr/bin/env python3
"""Read the versioned cache manifest and verify it against the GitHub release."""
import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


REPOSITORY = "disposabl-dev/disposabl-exact"
MAX_MANIFEST_SIZE = 1024 * 1024


def read_manifest(tag, ref, bun):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "disposabl-exact-setup"}
    if token := os.environ.get("GH_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    request = Request(f"https://api.github.com/repos/{REPOSITORY}/releases/tags/{tag}", headers=headers)
    try:
        with urlopen(request, timeout=30) as response:
            release = json.load(response)
    except HTTPError as error:
        if error.code == 404:
            return None
        raise
    if release.get("draft") or release.get("tag_name") != tag:
        return None
    assets = {asset["name"]: asset for asset in release["assets"] if asset["state"] == "uploaded"}
    index = assets.get("inputs.json")
    if not index or not index.get("digest"):
        return None
    if not 0 < index["size"] <= MAX_MANIFEST_SIZE:
        raise ValueError("Release has no valid inputs.json asset")
    url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/inputs.json"
    with urlopen(url, timeout=30) as response:
        data = response.read(MAX_MANIFEST_SIZE + 1)
    if len(data) != index["size"] or index.get("digest") != "sha256:" + hashlib.sha256(data).hexdigest():
        raise ValueError("Release manifest differs from the GitHub asset digest")
    manifest = json.loads(data)
    required = {"sdk.tar.zst", "cargo-android.zst", "cargo-gradle.zst", "cargo-ios.zst",
                "ios-baker.json", "ios-source-times.json"}
    required.update(f"exact-{ref}-{platform}-bun-{bun}.tar.zst"
                    for platform in ("web-Linux-X64", "android-Linux-X64", "ios-macOS-ARM64"))
    link_kits = json.loads((Path(__file__).resolve().parent.parent / "ios-link-hooks.json").read_text())
    if ref in link_kits or "ios-host-catalog.zst" in manifest:
        required.update(("ios-link-kit.zst", "ios-host-catalog.zst"))
    if missing := sorted(required.difference(manifest)):
        raise ValueError("Release manifest is missing " + ", ".join(missing))
    for name, recorded in manifest.items():
        asset = assets.get(name)
        if not asset or not asset.get("digest"):
            return None
        digest = recorded.get("sha256", "")
        size = recorded.get("size")
        if (not re.fullmatch(r"[A-Za-z0-9_.-]+", name) or not re.fullmatch(r"[a-f0-9]{64}", digest)
                or type(size) is not int or not 0 < size < 2_000_000_000
                or size != asset["size"] or asset["digest"] != "sha256:" + digest):
            raise ValueError(f"Release asset does not match the manifest: {name}")
    return data


def check_publisher(sha):
    url = f"https://api.github.com/repos/{REPOSITORY}/actions/workflows/publish.yml/runs?head_sha={sha}&event=push&per_page=1"
    try:
        with urlopen(Request(url, headers={"User-Agent": "disposabl-exact-setup"}), timeout=15) as response:
            runs = json.load(response)["workflow_runs"]
    except OSError:
        return
    if runs and runs[0]["conclusion"] in ("failure", "cancelled", "timed_out", "startup_failure", "action_required"):
        raise ValueError(f"Exact cache publication failed: {runs[0]['html_url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("ref")
    parser.add_argument("bun")
    parser.add_argument("output", type=Path)
    parser.add_argument("--wait", type=int, default=0)
    parser.add_argument("--producer-sha", default="")
    args = parser.parse_args()
    if (not re.fullmatch(r"[1-9][0-9]*", args.version) or not re.fullmatch(r"[a-f0-9]{40}", args.ref)
            or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.bun) or args.wait < 0
            or (args.producer_sha and not re.fullmatch(r"[a-f0-9]{40}", args.producer_sha))):
        parser.error("Expected a bundle format version, full Exact SHA, and Bun version")
    tag = f"v{args.version}-exact-{args.ref}-bun-{args.bun}"
    deadline = time.monotonic() + args.wait
    next_publisher_check = 0
    while (data := read_manifest(tag, args.ref, args.bun)) is None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError(f"Exact compiler caches have not been published for {tag}")
        if args.producer_sha and time.monotonic() >= next_publisher_check:
            check_publisher(args.producer_sha)
            next_publisher_check = time.monotonic() + 180
        print(f"Waiting for the Exact cache publisher to release {tag}", flush=True)
        time.sleep(min(30, remaining))
    args.output.write_bytes(data)
    print(f"Verified Exact setup and compiler cache metadata for {tag}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        sys.exit(str(error))
