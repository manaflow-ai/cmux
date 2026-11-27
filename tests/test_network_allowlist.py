#!/usr/bin/env python3
"""Network allowlist guard: every connectivity host cmux NEXT's code names is in config/network/allowlist.json.

Some corporate firewalls let through only listed hosts and addresses. config/network/allowlist.json is the one list
of what a cmux NEXT client (the Mac app, its daemon, the iPhone app) reaches for relay and connectivity: TURN and
STUN servers, the managed relays, signaling and backend APIs, update hosts, with ports, protocols and the address
ranges where they are fixed (ultra-connectivity ledger row 80, RFD 0142 item O7). docs/network-requirements.md is
rendered from it.

A connectivity host is one of:

  ice      the host of a `stun:`, `stuns:`, `turn:` or `turns:` URI in NEXT's source (the host guard's scope) or in
           the servers that hand ICE lists to clients (ICE_SERVERS)
  relay    a relay URL in config/iroh/managed-relay-catalog.json (the signed catalog the apps get)
  backend  a host tests/test_outbound_hosts.py finds in NEXT's code whose docs/privacy.md row says `connects`, when
           it is first-party (FIRST_PARTY) or its name says stun, turn, relay, signal or rtc

The test fails when one of them has no entry (add it, with its ports and what it is for), when an entry the code
named is no longer in the code (named_in "code") or a relay left the catalog (named_in "catalog"), so the list stays
exact, when an entry is malformed, and when the doc differs from the JSON. An entry named_in "server-answer" is a
host a server hands out at run time (Cloudflare's TURN host in the /v1/ice answer); no scan can find it.

On a pull request (CMUX_GUARDS_BASE_SHA set) the coverage check reads only the files the change touched, at the
base and at the head (tests/guard_delta.py): a connectivity host they gained with no entry fails, and a host they
lost is looked up across the tree (outbound hosts' git grep, and one for its ICE URIs) before a named_in "code"
entry is called stale. A change to RULES (the list, the relay catalog, docs/privacy.md, the scanners) scans
everything, as does a branch's own run.

Run it: python3 tests/test_network_allowlist.py. Rewrite the doc after editing the JSON: --write.
Print the counts: --json.
"""

from __future__ import annotations

import fnmatch
import ipaddress
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_classic_cloud_routes import clean, in_scope  # noqa: E402
import guard_delta  # noqa: E402
import test_outbound_hosts as outbound  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = ROOT / "config" / "network" / "allowlist.json"
DOC = ROOT / "docs" / "network-requirements.md"
CATALOG = ROOT / "config" / "iroh" / "managed-relay-catalog.json"
# A change to one of these scans everything: what the coverage check reads besides the code (guard_delta.py adds
# itself).
RULES = ["tests/test_network_allowlist.py", *outbound.RULES, "config/network/allowlist.json",
         "config/iroh/managed-relay-catalog.json", "docs/privacy.md"]
FIRST_PARTY = ("cmux.dev", "cmux.com", "chatmux.dev", "debussy.workers.dev")
CONNECTIVITY_WORD = re.compile(r"stun|turn|relay|signal|rtc")
# Servers whose ICE lists reach the clients: the iPhone pairing API's /v1/ice and the device hub.
ICE_SERVERS = ("cmux-next-ios/backend/src/", "workers/device-hub/src/")
ICE_SCOPE = {"include": [*outbound.SCAN["include"], *ICE_SERVERS],
             "exclude": [x for x in outbound.SCAN["exclude"] if x != "cmux-next-ios/backend/"]}
ICE = re.compile(rf"(?<![\w.+-])(?:stun|turn)s?:((?:{outbound.LABEL}\.)+{outbound.LABEL})(?![\w-])", re.I)

CATEGORIES = ("relay", "turn", "stun", "signaling", "backend", "auth", "updates")
BUILDS = ("release", "dev")
NAMED_IN = ("code", "catalog", "server-answer")
IPS = ("cloudflare", "dns")
PORT = re.compile(r"^(tcp|udp)/([1-9][0-9]{0,4})$")


def load(path: Path = ALLOWLIST) -> dict:
    return json.loads(path.read_text())


def ice_hosts(root: Path = ROOT) -> dict[str, list[str]]:
    """{host: [file, ...]} for every stun/turn URI host in scope, comments and test modules blanked."""
    p = subprocess.run(["git", "-C", str(root), "grep", "-I", "-l", "-z", "-E", "-i", "(stun|turn)s?:[a-z0-9]",
                        "--", *ICE_SCOPE["include"]], capture_output=True)
    if p.returncode not in (0, 1):
        raise RuntimeError(p.stderr.decode(errors="replace"))
    found: dict[str, list[str]] = {}
    for rel in sorted(r for r in p.stdout.decode().split("\0") if r and in_scope(r, ICE_SCOPE)):
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        for host in sorted(ice_hosts_in(path.read_text(encoding="utf-8", errors="replace"), rel)):
            found.setdefault(host, []).append(rel)
    return found


def ice_found_in(texts: dict[str, str]) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for rel in sorted(texts):
        if in_scope(rel, ICE_SCOPE):
            for host in sorted(ice_hosts_in(texts[rel], rel)):
                found.setdefault(host, []).append(rel)
    return found


def ice_named_anywhere(hosts: set[str], root: Path = ROOT) -> set[str]:
    """Which of `hosts` an ICE URI in scope names: a git grep for each, then the matcher on those files."""
    if not hosts:
        return set()
    argv = ["git", "-C", str(root), "grep", "-I", "-l", "-z", "-i", "-F"]
    for host in sorted(hosts):
        argv += ["-e", host]
    p = subprocess.run([*argv, "--", *ICE_SCOPE["include"]], capture_output=True)
    if p.returncode not in (0, 1):
        raise RuntimeError(p.stderr.decode(errors="replace"))
    rels = [r for r in p.stdout.decode().split("\0") if r]
    return set(ice_found_in(guard_delta.text_at_head(rels, root, errors="replace"))) & hosts


def ice_hosts_in(text: str, rel: str) -> set[str]:
    out = set()
    for m in ICE.finditer(clean(text, Path(rel).suffix)):
        host = m.group(1).lower()
        if not outbound.RESERVED.search(host):
            out.add(host)
    return out


def relay_hosts(path: Path = CATALOG) -> set[str]:
    return {re.sub(r"^\w+://", "", r["url"]).split("/")[0].lower() for r in json.loads(path.read_text())["relays"]}


def is_connectivity(host: str) -> bool:
    first_party = any(host == s or host.endswith("." + s) for s in FIRST_PARTY)
    return first_party or bool(CONNECTIVITY_WORD.search(host))


def code_hosts(found: dict[str, dict[str, list[int]]], privacy_doc: str) -> dict[str, list[str]]:
    """{host: [file, ...]}: the hosts the outbound scan found that a connectivity allowlist must hold."""
    rows, _ = outbound.listed(privacy_doc)
    return {h: sorted(files) for h, files in found.items()
            if rows.get(h, ("connects", ""))[0] == "connects" and is_connectivity(h)}


def covered(host: str, listed: set[str]) -> bool:
    return host in listed or any("*" in pat and fnmatch.fnmatchcase(host, pat) for pat in listed)


def entry_problems(data: dict) -> list[str]:
    out = []
    seen: set[str] = set()
    for e in data["hosts"]:
        h = e.get("host", "")
        if h in seen:
            out.append(f"{h}: listed twice")
        seen.add(h)
        for key, allowed in (("category", CATEGORIES), ("named_in", NAMED_IN), ("ips", IPS)):
            if e.get(key) not in allowed:
                out.append(f"{h}: {key} {e.get(key)!r} is not one of {allowed}")
        if not e.get("builds") or any(b not in BUILDS for b in e["builds"]):
            out.append(f"{h}: builds must be a non-empty subset of {BUILDS}")
        if not e.get("purpose", "").strip():
            out.append(f"{h}: say what it is for (purpose)")
        if not e.get("ports"):
            out.append(f"{h}: no ports")
        for p in e.get("ports", []):
            m = PORT.match(p.get("port", ""))
            if not m or not 0 < int(m.group(2)) < 65536 or not p.get("use", "").strip():
                out.append(f"{h}: port {p!r} must be tcp/N or udp/N with a use")
        for ip in e.get("observed", {}).get("addresses", []):
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                out.append(f"{h}: observed address {ip!r} is not an IP address")
    cf = data["ip_ranges"]["cloudflare"]
    for net in cf["ipv4"] + cf["ipv6"]:
        try:
            ipaddress.ip_network(net)
        except ValueError:
            out.append(f"cloudflare range {net!r} is not a network")
    pops = data["own_pops"]
    if pops.get("status") != "bought" and (pops.get("hosts") or pops.get("ipv4") or pops.get("ipv6")):
        out.append("own_pops lists addresses while its status is not \"bought\"")
    return out


def coverage_problems(data: dict, code: dict[str, list[str]], ice: dict[str, list[str]], relays: set[str],
                      named: set[str] | None = None) -> list[str]:
    """`code`: the connectivity hosts the code names; `named`: every host it names (default: `code`)."""
    named = set(code) | set(ice) | (named or set())
    listed = {e["host"] for e in data["hosts"]}
    out = []
    for host, files in sorted({**code, **ice}.items()):
        if not covered(host, listed):
            out.append(f"{host} (in {', '.join(files[:3])}) is a connectivity host with no entry in "
                       "config/network/allowlist.json: add it with its ports and what it is for, then --write")
    for host in sorted(relays):
        if host not in listed:
            out.append(f"{host}: a relay in config/iroh/managed-relay-catalog.json with no allowlist entry")
    for e in data["hosts"]:
        h, how = e["host"], e["named_in"]
        if how == "code" and h not in named:
            out.append(f"{h}: named_in code, but the code no longer names it: remove the entry")
        if how == "catalog" and h not in relays:
            out.append(f"{h}: named_in catalog, but the relay catalog no longer lists it: remove the entry")
    return out


def change_problems(base: str, paths: list[str], data: dict, privacy_doc: str, relays: set[str],
                    root: Path = ROOT) -> list[str]:
    """The coverage problems the change since `base` added, from the touched files alone (RULES unchanged, so the
    list, the catalog and the privacy rows are the base's)."""
    head_texts = guard_delta.text_at_head(paths, root, errors="replace")
    base_texts = guard_delta.blobs_at(base, paths, root, errors="replace")
    outbound_scope = lambda texts: {r: t for r, t in texts.items() if in_scope(r, outbound.SCAN)}  # noqa: E731
    head, was = outbound.found_in(outbound_scope(head_texts)), outbound.found_in(outbound_scope(base_texts))
    head_ice, was_ice = ice_found_in(head_texts), ice_found_in(base_texts)
    gained = {h: f for h, f in {**code_hosts(head, privacy_doc), **head_ice}.items()
              if h not in was and h not in was_ice}
    lost = (set(was) | set(was_ice)) - set(head) - set(head_ice)
    stale = {e["host"] for e in data["hosts"] if e["named_in"] == "code"} & lost
    named = set(outbound.named_anywhere(stale, root)) | ice_named_anywhere(stale, root)
    # coverage_problems on just these: the gained hosts' entries, and the named_in "code" entries for lost hosts.
    sub = {**data, "hosts": [e for e in data["hosts"] if e["named_in"] != "code" or e["host"] in stale or e["host"] in gained]}
    return coverage_problems(sub, gained, {}, relays, named | (set(head) | set(head_ice)))


def coverage(root: Path = ROOT) -> list[str]:
    """The coverage problems: on a pull request the change's own, else the whole tree's."""
    data, privacy_doc, relays = load(root / ALLOWLIST.relative_to(ROOT)), (root / "docs/privacy.md").read_text(), \
        relay_hosts(root / CATALOG.relative_to(ROOT))
    base = guard_delta.base_commit(root)
    paths = guard_delta.changed(RULES, root, base) if base else None
    if base and paths is not None:
        guard_delta.note("network allowlist", base, paths)
        return change_problems(base, paths, data, privacy_doc, relays, root)
    found = outbound.scan(root)
    return coverage_problems(data, code_hosts(found, privacy_doc), ice_hosts(root), relays, set(found))


def ports_text(e: dict) -> str:
    return "<br>".join(f"`{p['port']}` {p['use']}" for p in e["ports"])


def ips_text(e: dict) -> str:
    if e["ips"] == "cloudflare":
        return "Cloudflare's ranges (below)"
    seen = e.get("observed")
    if not seen:
        return "not fixed: allow the host name"
    return f"not fixed: allow the host name ({seen['date']} DNS: {', '.join(f'`{a}`' for a in seen['addresses'])})"


def render(data: dict) -> str:
    hosts = data["hosts"]
    lines = [
        "# Network requirements",
        "",
        "<!-- Generated from config/network/allowlist.json by python3 tests/test_network_allowlist.py --write; "
        "edit the JSON, not this page. -->",
        "",
        "Some firewalls let through only listed hosts and addresses. This page lists every host, port and protocol "
        "a cmux NEXT client (the Mac app, its daemon, the iPhone app) reaches for relay and connectivity. "
        "`tests/test_network_allowlist.py` fails when the code names a connectivity host this list lacks, so the "
        "list is complete for what it covers (ultra-connectivity ledger row 80, RFD 0142 item O7). Every host the "
        "app talks to for any reason is in [privacy.md](privacy.md).",
        "",
        "Allow outbound connections to the hosts below. Where a host's addresses are not fixed, allow it by name "
        "(a proxy or firewall that matches the TLS SNI or DNS name); addresses observed on a date are a hint, not a "
        "promise.",
        "",
    ]
    for title, release in (("Release builds", True), ("Development and staging builds only", False)):
        rows = [e for e in hosts if ("release" in e["builds"]) == release]
        lines += [f"## {title}", "", "| Host | Kind | Ports | Addresses | What for |", "| --- | --- | --- | --- | --- |"]
        for e in sorted(rows, key=lambda e: (CATEGORIES.index(e["category"]), e["host"])):
            lines.append(f"| `{e['host']}` | {e['category']} | {ports_text(e)} | {ips_text(e)} | {e['purpose']} |")
        lines.append("")
    lines += ["## Direct paths between your devices", "", data["peer_to_peer"], ""]
    cf = data["ip_ranges"]["cloudflare"]
    lines += ["## Cloudflare's ranges", "",
              f"{cf['note']} Source: {', '.join(cf['source'])} (fetched {cf['fetched']}).", "",
              "IPv4: " + ", ".join(f"`{n}`" for n in cf["ipv4"]), "",
              "IPv6: " + ", ".join(f"`{n}`" for n in cf["ipv6"]), ""]
    pops = data["own_pops"]
    addrs = pops["ipv4"] + pops["ipv6"]
    lines += ["## cmux's own points of presence", "",
              f"Status: {pops['status']}. Slot: {pops['slot']}. " +
              ("Addresses: " + ", ".join(f"`{a}`" for a in addrs) + "." if addrs else
               "No addresses yet; this section lists them, with their hosts, once the boxes exist."), ""]
    return "\n".join(lines)


def counts(data: dict) -> dict:
    by = {}
    for e in data["hosts"]:
        by[e["category"]] = by.get(e["category"], 0) + 1
    return {"hosts": len(data["hosts"]), "release": sum("release" in e["builds"] for e in data["hosts"]),
            "by_category": dict(sorted(by.items()))}


class NetworkAllowlist(unittest.TestCase):
    def test_entries_are_well_formed(self):
        bad = entry_problems(load())
        self.assertFalse(bad, "\n" + "\n".join(bad))

    def test_every_connectivity_host_in_the_code_is_listed(self):
        bad = coverage()
        self.assertFalse(bad, "\n" + "\n".join(bad))

    def test_the_doc_is_rendered_from_the_list(self):
        self.assertEqual(DOC.read_text(), render(load()),
                         "docs/network-requirements.md differs from config/network/allowlist.json: run --write")


class Matcher(unittest.TestCase):
    def test_ice_uris_are_found(self):
        ts = 'const STUN = "stun:stun.cloudflare.com:3478"\n// "turn:old.cmux.dev:3478"\n'
        self.assertEqual(ice_hosts_in(ts, "x/src/ice.ts"), {"stun.cloudflare.com"})
        rs = '"turns:turn.cloudflare.com:443?transport=tcp" "turn:turn.example.com:3478"'
        self.assertEqual(ice_hosts_in(rs, "x/src/a.rs"), {"turn.cloudflare.com"})
        self.assertEqual(ice_hosts_in('key = "turn:optchat:4"', "x/src/a.rs"), set())

    def test_connectivity_hosts(self):
        found = {"api.cmux.dev": {"a.swift": [1]}, "github.com": {"b.rs": [2]}, "stun.l.google.com": {"c.rs": [3]},
                 "cmux.com": {"d.swift": [4]}}
        privacy = "| `cmux.com` | opens | docs |\n| `api.cmux.dev` | connects | x |\n"
        self.assertEqual(set(code_hosts(found, privacy)), {"api.cmux.dev", "stun.l.google.com"})

    def test_missing_and_stale_entries_fail(self):
        data = {"hosts": [{"host": "*.debussy.workers.dev", "named_in": "server-answer"},
                          {"host": "gone.cmux.dev", "named_in": "code"},
                          {"host": "x.relay.cmux.dev", "named_in": "catalog"}]}
        bad = coverage_problems(data, {"a.debussy.workers.dev": ["f"], "new.cmux.dev": ["g"]}, {},
                                {"y.relay.cmux.dev"})
        self.assertEqual(len(bad), 4, bad)
        self.assertTrue(any(b.startswith("new.cmux.dev") for b in bad))

    def test_pops_need_status_bought(self):
        data = load()
        data["own_pops"] = {**data["own_pops"], "status": "not bought", "ipv4": ["192.0.2.1"]}
        self.assertTrue(any("own_pops" in b for b in entry_problems(data)))


if __name__ == "__main__":
    if "--write" in sys.argv:
        DOC.write_text(render(load()))
        print(json.dumps(counts(load())))
    elif "--json" in sys.argv:
        print(json.dumps(counts(load())))
    else:
        unittest.main()
