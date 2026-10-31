#!/usr/bin/env python3
"""Sync official releases from store.json into store-samin.json.

Keeps the private SideStore source up-to-date with official Nuvio releases
even when custom builds are pending, skipped, or in progress.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description="Sync official releases from store.json into store-samin.json")
    parser.add_argument("--official-source", default=Path("store.json"), type=Path)
    parser.add_argument("--samin-source", default=Path("store-samin.json"), type=Path)
    return parser.parse_args()


def ver_key(v_dict):
    v_str = v_dict.get("version", "0.0.0")
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-samin(\d+))?$", v_str)
    if m:
        major, minor, patch, samin_rev = m.groups()
        return (int(major), int(minor), int(patch), int(samin_rev or 0))
    parts = [int(p) if p.isdigit() else 0 for p in re.split(r"[\.\-]", v_str)]
    return tuple(parts)


def load_official_data(official_source: Path):
    # Try reading from upstream/cmp-rewrite git tree first (most up-to-date)
    for ref in ["upstream/cmp-rewrite:store.json", "HEAD:store.json"]:
        try:
            res = subprocess.run(
                ["git", "show", ref],
                capture_output=True,
                text=True,
                check=True,
            )
            data = json.loads(res.stdout)
            if data.get("apps"):
                return data
        except Exception:
            pass

    if official_source.is_file():
        with official_source.open(encoding="utf-8") as f:
            return json.load(f)

    return None


def main():
    args = parse_args()
    if not args.samin_source.is_file():
        print(f"Error: {args.samin_source} not found", file=sys.stderr)
        return 1

    official_data = load_official_data(args.official_source)
    if not official_data:
        print(f"Error: Could not load official store data from git or {args.official_source}", file=sys.stderr)
        return 1

    with args.samin_source.open(encoding="utf-8") as f:
        samin_data = json.load(f)

    official_app = next((a for a in official_data.get("apps", []) if a.get("bundleIdentifier") == "com.nuvio.media"), None)
    samin_app = next((a for a in samin_data.get("apps", []) if a.get("bundleIdentifier") == "com.nuvio.media"), None)

    if not official_app or not samin_app:
        print("Error: Could not find com.nuvio.media in both source files", file=sys.stderr)
        return 1

    # Sync app permissions / privacy
    official_perms = official_app.get("appPermissions", {})
    samin_perms = samin_app.setdefault("appPermissions", {})
    if "privacy" in official_perms and isinstance(official_perms["privacy"], dict):
        samin_privacy = samin_perms.setdefault("privacy", {})
        for k, v in official_perms["privacy"].items():
            if k not in samin_privacy:
                samin_privacy[k] = v

    samin_versions = samin_app.setdefault("versions", [])
    existing_ver_strings = {v["version"] for v in samin_versions}
    existing_build_strings = {v.get("buildVersion") for v in samin_versions if "buildVersion" in v}

    added_count = 0
    for official_ver in official_app.get("versions", []):
        ver_str = official_ver.get("version")
        build_str = official_ver.get("buildVersion")
        if ver_str not in existing_ver_strings and build_str not in existing_build_strings:
            samin_versions.append(official_ver)
            existing_ver_strings.add(ver_str)
            if build_str:
                existing_build_strings.add(build_str)
            added_count += 1
            print(f"Added official release: {ver_str} (build {build_str})")

    # Sort descending by version
    samin_versions.sort(key=ver_key, reverse=True)

    with args.samin_source.open("w", encoding="utf-8", newline="\n") as f:
        json.dump(samin_data, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"Synced {added_count} new official releases into {args.samin_source}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
