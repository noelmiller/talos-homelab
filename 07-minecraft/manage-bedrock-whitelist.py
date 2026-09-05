#!/usr/bin/env python3

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Dict, List, Optional


WHITELIST_PATH = Path(__file__).with_name("bedrock-whitelist.json")
XUID_API = "https://api.geysermc.org/v2/xbox/xuid/"


def load_whitelist() -> List[Dict[str, str]]:
    try:
        entries = json.loads(WHITELIST_PATH.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Unable to read {WHITELIST_PATH}: {error}") from error

    if not isinstance(entries, list):
        raise RuntimeError(f"{WHITELIST_PATH} must contain a JSON array")

    for entry in entries:
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("uuid"), str)
            or not isinstance(entry.get("name"), str)
        ):
            raise RuntimeError(
                f"{WHITELIST_PATH} entries must contain string uuid and name fields"
            )
    return entries


def save_whitelist(entries: List[Dict[str, str]]) -> None:
    entries.sort(key=lambda entry: entry["name"].casefold())
    temporary_path = WHITELIST_PATH.with_suffix(".json.tmp")
    temporary_path.write_text(json.dumps(entries, indent=2) + "\n")
    os.replace(temporary_path, WHITELIST_PATH)


def resolve_xuid(gamertag: str) -> int:
    url = XUID_API + urllib.parse.quote(gamertag, safe="")
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(
            f"Unable to resolve {gamertag!r}: Xbox lookup returned HTTP {error.code}. "
            "Verify the exact gamertag or provide --xuid."
        ) from error
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Unable to resolve {gamertag!r}: {error}") from error

    value = str(payload.get("xuid", ""))
    if not value.isdecimal():
        raise RuntimeError(f"Xbox lookup returned an invalid XUID for {gamertag!r}")
    return int(value)


def validate_xuid(value: str) -> int:
    if not value.isdecimal():
        raise RuntimeError("XUID must be an unsigned decimal integer")
    xuid = int(value)
    if not 0 <= xuid < 2**64:
        raise RuntimeError("XUID must fit in an unsigned 64-bit integer")
    return xuid


def floodgate_uuid(xuid: int) -> str:
    return str(uuid.UUID(int=xuid))


def floodgate_name(gamertag: str) -> str:
    return "." + gamertag.replace(" ", "_")


def add_player(gamertag: str, supplied_xuid: Optional[str]) -> None:
    xuid = validate_xuid(supplied_xuid) if supplied_xuid else resolve_xuid(gamertag)
    player_uuid = floodgate_uuid(xuid)
    player_name = floodgate_name(gamertag)
    entries = load_whitelist()

    for entry in entries:
        if entry["uuid"] == player_uuid:
            entry["name"] = player_name
            save_whitelist(entries)
            print(f"Updated {player_name} ({player_uuid})")
            return
        if entry["name"].casefold() == player_name.casefold():
            raise RuntimeError(
                f"{entry['name']} already exists with a different UUID: {entry['uuid']}"
            )

    entries.append({"uuid": player_uuid, "name": player_name})
    save_whitelist(entries)
    print(f"Added {player_name} ({player_uuid})")


def remove_player(gamertag: str) -> None:
    player_name = floodgate_name(gamertag)
    entries = load_whitelist()
    retained = [
        entry
        for entry in entries
        if entry["name"].casefold() != player_name.casefold()
    ]
    if len(retained) == len(entries):
        raise RuntimeError(f"{player_name} is not in the Bedrock whitelist")

    save_whitelist(retained)
    print(f"Removed {player_name}")


def list_players() -> None:
    entries = load_whitelist()
    if not entries:
        print("The Bedrock whitelist is empty")
        return
    for entry in sorted(entries, key=lambda item: item["name"].casefold()):
        print(f"{entry['name']}\t{entry['uuid']}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Manage the shared Floodgate Bedrock whitelist."
    )
    commands = parser.add_subparsers(dest="command", required=True)

    add_command = commands.add_parser("add", help="Add or update a Bedrock player")
    add_command.add_argument("gamertag", help="Exact Xbox gamertag without the dot prefix")
    add_command.add_argument(
        "--xuid",
        help="Known decimal Xbox XUID; skips the Geyser lookup",
    )

    remove_command = commands.add_parser("remove", help="Remove a Bedrock player")
    remove_command.add_argument(
        "gamertag", help="Exact Xbox gamertag without the dot prefix"
    )

    commands.add_parser("list", help="List Bedrock players and Floodgate UUIDs")
    if sys.argv[1:] == ["help"]:
        parser.print_help()
        parser.exit()
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    try:
        if args.command == "add":
            add_player(args.gamertag, args.xuid)
        elif args.command == "remove":
            remove_player(args.gamertag)
        else:
            list_players()
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
