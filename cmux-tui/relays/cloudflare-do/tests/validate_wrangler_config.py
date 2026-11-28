#!/usr/bin/env python3
import datetime
import pathlib
import tomllib


config_path = pathlib.Path(__file__).parents[1] / "wrangler.toml"
with config_path.open("rb") as config_file:
    config = tomllib.load(config_file)

compatibility_date = config["compatibility_date"]
if isinstance(compatibility_date, str):
    compatibility_date = datetime.date.fromisoformat(compatibility_date)

flags = set(config.get("compatibility_flags", []))
if (
    compatibility_date >= datetime.date(2026, 4, 7)
    and "web_socket_auto_reply_to_close" in flags
):
    raise SystemExit(
        "web_socket_auto_reply_to_close is implicit on compatibility dates at or after "
        "2026-04-07 and Cloudflare rejects deployments that still request it"
    )
