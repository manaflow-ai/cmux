#!/usr/bin/env python3
"""Write the request fields a phone may send on each daemon-lane command.

The phone's daemon lane (Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift)
is an allowlist of commands; this script writes the matching allowlist of fields per command from the
daemon's own request schema (cmux-tui/spec/sdk-schema.json), minus the fields that choose a program,
its directory or its environment (remote-relay-authorization.md: command-bearing params stay denied).
A field the daemon adds later is refused until this script runs again and the change is reviewed.

    python3 scripts/cmux-next/gen-phone-lane-fields.py           # write the Swift table
    python3 scripts/cmux-next/gen-phone-lane-fields.py --check   # exit 1 when it drifted
"""
import hashlib, json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SCHEMA = "cmux-tui/spec/sdk-schema.json"
POLICY = "Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift"
OUT = "Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy+Fields.generated.swift"
# Never from a phone, whatever the command: they choose what runs, where, and with which environment.
PROGRAM_FIELDS = {"respawn", "env", "shell_args", "argv", "command", "cwd"}
# Field types that are not plain values (opaque JSON, maps, objects) pass through to the daemon whole,
# so each one is allowed only after a review, by type or by command field. A new one stops the script.
# Each review pins the type's whole resolved shape (`shape_hash`): a field added anywhere inside it,
# such as a `command` in a nested object, stops the script until the review and its hash are updated.
REVIEWED_TYPES = {
    "PaneRef": ("a pane named by its numeric id or public pane_ id; the daemon resolves it in its own tree",
                "b23ae39eaed8f1d7"),
    "TabRef": ("a tab named by its numeric surface id or public tab_ id; the daemon resolves it in its own tree",
               "aa168c418c03be91"),
    # Narrows a `send`: the daemon writes only while the terminal's agent waits at its prompt in this
    # harness session. One optional string; it names no program, directory or environment.
    "SendExpectAgent": ("an agent's harness session id that a send must still match; it only narrows the write",
                        "201877f6931063f5"),
}
REVIEWED_FIELDS = {
    ("put-frontend-projection", "projection"): ("the phone's own personal projection; the lane checks scope and subject",
                                                "d7e14019f9227131"),
    ("move-tab-to-column", "dock"): ("ColumnPin: an edge and a width for docking a column",
                                     "1b92a6de6fe0171a"),
    ("resize-attached-view", "identity"): ("SizingIdentity: whose size lease this is",
                                           "603297ce84b828a2"),
    ("set-host-size-policy", "policy"): ("HostSizePolicyRequest: a mode name and a list of device tokens; the "
                                         "daemon validates both and writes two settings keys, nothing else",
                                         "17f8e98fe6f266e3"),
    ("clear-history", "fallback_key"): ("TerminalKeyInput: a key to send when the surface cannot clear",
                                        "a5c09e7823e98e46"),
    # This lane refuses new-conversation-tab outright (DaemonLanePolicy.evaluate); cmux-mobile-host is the
    # lane that forwards it, with its own agent_session review (cmux-mobile-host/src/policy.rs).
    ("new-conversation-tab", "agent_session"): ("AgentSessionSource: four strings naming the acpmux session a "
                                                "tab shows (host, session, harness, host_name); the daemon "
                                                "only records them and starts nothing",
                                                "db5f27c4f0aa2ac2"),
    ("new-conversation-tab", "split"): ("ConversationTabSplit: a side and caller-minted pane_/split_ ids "
                                        "for placing the tab in a new pane",
                                        "51c9b9b2ab895f7a"),
}


def resolved(types, t, seen=()):
    """`t` with every named type expanded in place (a cycle stays a name), for `shape_hash`."""
    if isinstance(t, dict):
        if t.get("kind") == "ref" and t.get("name") in types and t.get("name") not in seen:
            name = t["name"]
            return {"ref": name, "is": resolved(types, types[name], seen + (name,))}
        return {k: resolved(types, v, seen) for k, v in sorted(t.items()) if k not in ("description", "doc", "docs")}
    if isinstance(t, list):
        return [resolved(types, v, seen) for v in t]
    return t


def shape_hash(types, t):
    canonical = json.dumps(resolved(types, t), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def check_review(label, pinned, types, t):
    got = shape_hash(types, t)
    if pinned != got:
        raise SystemExit("%s: the reviewed shape of %s changed (pinned %s, now %s); review every field in it, "
                         "then update its hash in %s" % (SCHEMA, label, pinned, got, os.path.basename(__file__)))


def plain(types, t):
    """True for a value the lane can pass on without review: scalars, enums, aliases of scalars,
    and arrays of those."""
    kind = t.get("kind")
    if kind in ("scalar", "enum"):
        return True
    if kind == "array":
        return plain(types, t.get("items") or {})
    if kind == "ref":
        target = types.get(t.get("name"), {})
        if target.get("kind") == "enum":
            return True
        if target.get("kind") == "alias":
            return plain(types, target.get("target") or {})
    return False


def type_name(t):
    if t.get("kind") == "ref":
        return t.get("name")
    if t.get("kind") == "array":
        return type_name(t.get("items") or {})
    return None


def allowed_commands():
    src = open(os.path.join(ROOT, POLICY), encoding="utf-8").read()
    start = src.index("allowedCommands: Set<String> = [")
    block = src[start:src.index("]", start)]
    return sorted(set(re.findall(r'"([a-z0-9-]+)"', block)))


def table():
    schema = json.load(open(os.path.join(ROOT, SCHEMA), encoding="utf-8"))
    commands, types = schema["commands"], schema.get("types", {})
    rows = []
    for name in allowed_commands():
        if name not in commands:
            raise SystemExit("%s: %s is allowed for phones but not in %s" % (POLICY, name, SCHEMA))
        request = commands[name].get("request") or {}
        if request.get("kind") not in (None, "object") or request.get("additional_properties"):
            raise SystemExit("%s: %s takes open-ended params; review it by hand" % (SCHEMA, name))
        fields = []
        for field, spec in sorted((request.get("fields") or {}).items()):
            if field in PROGRAM_FIELDS:
                continue
            t = spec.get("type") or {}
            if not plain(types, t) and (name, field) in REVIEWED_FIELDS:
                check_review("%s.%s" % (name, field), REVIEWED_FIELDS[(name, field)][1], types, t)
            elif not plain(types, t) and type_name(t) in REVIEWED_TYPES:
                check_review(type_name(t), REVIEWED_TYPES[type_name(t)][1], types, types.get(type_name(t), {}))
            elif not plain(types, t):
                raise SystemExit("%s: %s.%s has free-form type %s; review it and add it to REVIEWED_TYPES or "
                                 "REVIEWED_FIELDS in %s" % (SCHEMA, name, field, json.dumps(t), os.path.basename(__file__)))
            fields.append(field)
        rows.append('        "%s": [%s],' % (name, ", ".join('"%s"' % f for f in fields)))
    return rows


def render():
    return "\n".join([
        "// GENERATED by scripts/cmux-next/gen-phone-lane-fields.py from",
        "// cmux-tui/spec/sdk-schema.json. Do not edit; rerun the script and review the change.",
        "",
        "extension DaemonLanePolicy {",
        "    /// The request fields a phone may send on each allowed command (besides `id` and `cmd`): the",
        "    /// daemon's request schema minus the fields that choose a program, its directory or environment.",
        "    static let commandFields: [String: Set<String>] = [",
        *table(),
        "    ]",
        "}",
        "",
    ])


def main():
    text = render()
    path = os.path.join(ROOT, OUT)
    if "--check" in sys.argv[1:]:
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if current != text:
            print("stale: %s (run scripts/cmux-next/gen-phone-lane-fields.py)" % OUT)
            return 1
        return 0
    open(path, "w", encoding="utf-8").write(text)
    print("wrote %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
