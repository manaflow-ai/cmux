#!/usr/bin/env python3
"""Per-person cmux NEXT update channels (.github/nightly-channels.json).

A channel is one person's own update feed: cmux-next.yml compiles a pushed
branch with the channel's app identity, nightly-channel.yml signs that app on
nightly-next and publishes it to <feed_base>/<channel>/appcast-arm64.xml, and
the person's installed app follows the feed (scripts/cmux-next/nightly-channel.sh
sets updates.test_feed). plans/cmux-next/nightly-channel.md has the design.

  validate
      Exits 1 when the config is malformed.
  identity CHANNEL [--github-output FILE]
      Prints KEY=VALUE lines: channel, identity, bundle_id, app_name,
      url_scheme, entitlements, provisioning_profile (true|false),
      return_feed, feed_base, feed_url, r2_bucket, r2_prefix,
      sparkle_channel.
  channel-for LOGIN
      Prints the one channel LOGIN may build; exits 1 when there is none or
      more than one (pass --channel to the script then).
  check-source --channel C --run FILE --sha SHA --repo OWNER/NAME
      FILE is the GitHub API JSON of the cmux-next.yml run that compiled the
      app. Exits 1 unless that run is a finished channel compile of SHA in
      REPO, started by one of the channel's actors.
  check-appcast --channel C --appcast FILE --build B --archive NAME
      Exits 1 unless FILE offers exactly one item: build B, the channel's
      sparkle:channel, an EdDSA signature, and NAME under the channel's feed.

Run names: a channel compile is titled `cmux NEXT channel <channel> · <sha>`
(cmux-next.yml run-name), which is how the signer finds what it may sign.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".github" / "nightly-channels.json"
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
SHA = re.compile(r"^[0-9a-f]{40}$")
BUILD = re.compile(r"^[0-9]+$")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SOURCE_WORKFLOW = ".github/workflows/cmux-next.yml"
IDENTITY_KEYS = ("bundle_id", "app_name", "url_scheme", "entitlements", "provisioning_profile", "return_feed")
# The real feeds a channel must never write over (nightly.yml NIGHTLY_NEXT_FEED_BASE,
# NIGHTLY_NEXT_LEGACY_FEED_BASE and main's NIGHTLY): a channel feed lives under feed_base.
CHANNELS_SEGMENT = "/channels"


class Refused(Exception):
    pass


def title(channel: str, sha: str) -> str:
    return f"cmux NEXT channel {channel} · {sha}"


def load(path: Path = CONFIG) -> dict:
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Refused(f"cannot read {path}: {error}") from error
    validate(config)
    return config


def validate(config: dict) -> None:
    if config.get("schema") != 1:
        raise Refused("schema must be 1")
    feed_base = config.get("feed_base", "")
    if not (feed_base.startswith("https://") and feed_base.endswith(CHANNELS_SEGMENT)):
        raise Refused(f"feed_base must be an https URL ending in {CHANNELS_SEGMENT}: {feed_base!r}")
    prefix = config.get("r2_prefix", "")
    if not (prefix.endswith(CHANNELS_SEGMENT.lstrip("/") + "/") and not prefix.startswith("/")):
        raise Refused(f"r2_prefix must end in channels/: {prefix!r}")
    # The public feed URL and the object key name the same file.
    if not feed_base.endswith("/" + prefix.rstrip("/")):
        raise Refused(f"feed_base {feed_base!r} does not serve r2_prefix {prefix!r}")
    if not config.get("r2_bucket") or not config.get("sparkle_channel"):
        raise Refused("r2_bucket and sparkle_channel are required")
    identities = config.get("identities")
    if not isinstance(identities, dict) or not identities:
        raise Refused("identities must be a non-empty object")
    for name, identity in identities.items():
        missing = [key for key in IDENTITY_KEYS if key not in identity]
        if missing:
            raise Refused(f"identity {name} lacks {', '.join(missing)}")
        if not isinstance(identity["provisioning_profile"], bool):
            raise Refused(f"identity {name}: provisioning_profile must be true or false")
        if not identity["return_feed"].startswith("https://") or CHANNELS_SEGMENT + "/" in identity["return_feed"]:
            raise Refused(f"identity {name}: return_feed must be a real https feed, not a channel")
    channels = config.get("channels")
    if not isinstance(channels, dict):
        raise Refused("channels must be an object")
    for name, channel in channels.items():
        if not NAME.match(name):
            raise Refused(f"channel name {name!r} must match {NAME.pattern}")
        if channel.get("identity") not in identities:
            raise Refused(f"channel {name}: unknown identity {channel.get('identity')!r}")
        actors = channel.get("actors")
        if not isinstance(actors, list) or not actors or not all(isinstance(a, str) and LOGIN.match(a) for a in actors):
            raise Refused(f"channel {name}: actors must be a non-empty list of GitHub logins")


def channel(config: dict, name: str) -> dict:
    if name not in config["channels"]:
        raise Refused(f"no channel {name!r} in .github/nightly-channels.json")
    return config["channels"][name]


def identity(config: dict, name: str) -> dict[str, str]:
    entry = channel(config, name)
    ident = config["identities"][entry["identity"]]
    feed_base = f"{config['feed_base']}/{name}"
    values = {
        "channel": name,
        "identity": entry["identity"],
        **{key: ident[key] for key in IDENTITY_KEYS},
        "feed_base": feed_base,
        "feed_url": f"{feed_base}/appcast-arm64.xml",
        "r2_bucket": config["r2_bucket"],
        "r2_prefix": f"{config['r2_prefix']}{name}/",
        "sparkle_channel": config["sparkle_channel"],
    }
    values["provisioning_profile"] = "true" if ident["provisioning_profile"] else "false"
    return values


def channel_for(config: dict, login: str) -> str:
    matches = [name for name, entry in config["channels"].items() if login.lower() in (a.lower() for a in entry["actors"])]
    if len(matches) != 1:
        raise Refused(f"{login} may build {len(matches)} channels ({', '.join(matches) or 'none'}); pass --channel")
    return matches[0]


def check_source(config: dict, name: str, run: dict, sha: str, repo: str) -> None:
    entry = channel(config, name)
    if not SHA.match(sha):
        raise Refused(f"{sha!r} is not a full commit SHA")
    checks = {
        "path": (run.get("path"), SOURCE_WORKFLOW),
        "event": (run.get("event"), "workflow_dispatch"),
        "status": (run.get("status"), "completed"),
        "head_sha": (run.get("head_sha"), sha),
        "head_repository": ((run.get("head_repository") or {}).get("full_name"), repo),
        "display_title": (run.get("display_title"), title(name, sha)),
    }
    for field, (actual, expected) in checks.items():
        if actual != expected:
            raise Refused(f"source run {field} is {actual!r}, expected {expected!r}")
    allowed = {actor.lower() for actor in entry["actors"]}
    # A re-run keeps the original actor and names the re-runner as triggering_actor: both count.
    for field in ("actor", "triggering_actor"):
        login = ((run.get(field) or {}).get("login") or "").lower()
        if login not in allowed:
            raise Refused(f"source run {field} {login or '<none>'} may not build channel {name}")


def check_appcast(config: dict, name: str, appcast: Path, build: str, archive: str) -> None:
    values = identity(config, name)
    if not BUILD.match(build):
        raise Refused(f"build {build!r} is not a number")
    root = ET.parse(appcast).getroot()
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise Refused(f"{appcast} has {len(items)} items, expected 1")
    item = items[0]
    version = item.findtext(f"{{{SPARKLE_NS}}}version")
    if version != build:
        raise Refused(f"item sparkle:version {version!r} is not build {build}")
    sparkle_channel = item.findtext(f"{{{SPARKLE_NS}}}channel")
    if sparkle_channel != values["sparkle_channel"]:
        raise Refused(f"item sparkle:channel {sparkle_channel!r} is not {values['sparkle_channel']!r}")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise Refused("item has no enclosure")
    url = enclosure.get("url", "")
    if url != f"{values['feed_base']}/{archive}":
        raise Refused(f"enclosure {url!r} is not {values['feed_base']}/{archive}")
    if not enclosure.get(f"{{{SPARKLE_NS}}}edSignature"):
        raise Refused("enclosure has no sparkle:edSignature")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=CONFIG)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    p = sub.add_parser("identity")
    p.add_argument("channel")
    p.add_argument("--github-output", type=Path)
    p = sub.add_parser("channel-for")
    p.add_argument("login")
    p = sub.add_parser("check-source")
    p.add_argument("--channel", required=True)
    p.add_argument("--run", type=Path, required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--repo", required=True)
    p = sub.add_parser("check-appcast")
    p.add_argument("--channel", required=True)
    p.add_argument("--appcast", type=Path, required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--archive", required=True)
    args = parser.parse_args(argv)
    try:
        config = load(args.config)
        if args.command == "identity":
            lines = [f"{key}={value}" for key, value in identity(config, args.channel).items()]
            print("\n".join(lines))
            if args.github_output:
                with args.github_output.open("a", encoding="utf-8") as out:
                    out.write("\n".join(lines) + "\n")
        elif args.command == "channel-for":
            print(channel_for(config, args.login))
        elif args.command == "check-source":
            check_source(config, args.channel, json.loads(args.run.read_text(encoding="utf-8")), args.sha, args.repo)
            print(f"source run is a channel {args.channel} compile of {args.sha}")
        elif args.command == "check-appcast":
            check_appcast(config, args.channel, args.appcast, args.build, args.archive)
            print(f"{args.appcast} offers build {args.build} on channel {args.channel}")
    except Refused as error:
        print(f"nightly_channel: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
