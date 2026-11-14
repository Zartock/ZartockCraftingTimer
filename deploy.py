#!/usr/bin/env python3
"""Packages the addon and uploads it to CurseForge.

    CF_API_TOKEN=... ./deploy.py [release|beta|alpha]
    ./deploy.py --dry-run            # only build the zip

The addon version and the game version both come from the .toc: Interface
16001 means game version 1.60.1. Set GAME_VERSION if CurseForge calls it
something else, and CHANGELOG to override the changelog text (markdown).
Create the token at https://authors.curseforge.com/#/account/api-tokens
"""

import json
import os
import re
import sys
import zipfile
from pathlib import Path

import requests

PROJECT_ID = 1803389  # https://authors.curseforge.com/#/projects/1803389
API = "https://wow.curseforge.com/api"

ROOT = Path(__file__).resolve().parent
TOC = next(ROOT.glob("*.toc"))
ADDON = TOC.stem


def read_toc_field(name):
    match = re.search(rf"^## {name}:\s*(\S+)", TOC.read_text(), re.MULTILINE)
    if not match:
        sys.exit(f"No '## {name}:' line in {TOC.name}.")
    return match.group(1)


def read_game_version():
    """Interface 16001 -> 1.60.1"""
    interface = int(read_toc_field("Interface"))
    return f"{interface // 10000}.{interface // 100 % 100}.{interface % 100}"


def build_zip(version):
    """The zip holds one folder named after the addon, with only the files the
    game needs: the .toc, the Lua files and the textures."""
    files = [TOC, *sorted(ROOT.glob("*.lua")), *sorted(ROOT.glob("*.tga"))]

    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    path = dist / f"{ADDON}-{version}.zip"

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in files:
            archive.write(file, f"{ADDON}/{file.name}")

    print(f"Built {path}:")
    for file in files:
        print(f"  {ADDON}/{file.name}")

    return path


def find_game_version_ids(session, name):
    response = session.get(f"{API}/game/versions")
    response.raise_for_status()
    versions = response.json()

    ids = [version["id"] for version in versions if version["name"] == name]
    if not ids:
        prefix = name.rsplit(".", 1)[0]
        similar = sorted({v["name"] for v in versions if v["name"].startswith(prefix)})
        sys.exit(f"CurseForge has no game version named '{name}'. Similar names: {', '.join(similar)}")

    return ids


def upload(session, zip_path, version, game_version, release_type):
    metadata = {
        "changelog": os.environ.get("CHANGELOG", f"Version {version}"),
        "changelogType": "markdown",
        "displayName": f"{ADDON} {version}",
        "releaseType": release_type,
        "gameVersions": find_game_version_ids(session, game_version),
    }

    print(f"Uploading {ADDON} {version} ({release_type}) for game version {game_version}...")

    with open(zip_path, "rb") as file:
        response = session.post(
            f"{API}/projects/{PROJECT_ID}/upload-file",
            data={"metadata": json.dumps(metadata)},
            files={"file": (zip_path.name, file)},
        )

    if not response.ok:
        sys.exit(f"Upload failed (HTTP {response.status_code}): {response.text}")

    print(f"Uploaded. File id: {response.json()['id']}")
    print(f"https://authors.curseforge.com/#/projects/{PROJECT_ID}/files")


def main():
    args = sys.argv[1:]

    version = read_toc_field("Version")
    zip_path = build_zip(version)

    if args == ["--dry-run"]:
        return

    release_type = args[0] if args else "release"
    if len(args) > 1 or release_type not in ("release", "beta", "alpha"):
        sys.exit(f"Usage: CF_API_TOKEN=... {sys.argv[0]} [release|beta|alpha]")

    game_version = os.environ.get("GAME_VERSION") or read_game_version()

    if not PROJECT_ID:
        sys.exit("Set PROJECT_ID at the top of deploy.py.")

    token = os.environ.get("CF_API_TOKEN")
    if not token:
        sys.exit("Set CF_API_TOKEN to your CurseForge API token.")

    session = requests.Session()
    session.headers["X-Api-Token"] = token

    upload(session, zip_path, version, game_version, release_type)


if __name__ == "__main__":
    main()
