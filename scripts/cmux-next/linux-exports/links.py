"""plans/cmux-next/links.json without Swift: DeepLinkExport.json() as LinkExportTests calls it.

What changes with the code is read from it: the DeepLink constants (DeepLink.swift) and each
build's scheme and bundle id (LinkExportTests.swift: the schemes come from CloudConfiguration,
which asks the Rust FFI, and theExportStatesWhatTheCodeDoes pins the exact list, so a green Swift
run writes the list that test states). The prose of DeepLinkExport.json(), and DeepLink.url's
shape, are mirrored here and fingerprinted: any edit to them raises SwiftShapeChanged (exit 2,
the Mac decides) until this file follows it and the fingerprint is updated.
"""
from __future__ import annotations

import hashlib
import re

import djson
import swift_data

DEEPLINK = swift_data.PKG + "/CmuxNextActions/DeepLink/DeepLink.swift"
EXPORT = swift_data.PKG + "/CmuxNextActions/DeepLink/DeepLinkExport.swift"
TEST = "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/LinkExportTests.swift"
OUT = "plans/cmux-next/links.json"

# sha256 of DeepLinkExport.swift, and of DeepLink.url(scheme:)'s body, that this file mirrors.
FINGERPRINTS = {
    "DeepLinkExport.swift": "fb5320189b7c9d1ee643b4b22154ae4038c72671aa6dc930d502fd6b675688f8",
    "DeepLink.url": "b05e93919f24813be5d679fcc75013624e10051c988bf2432b39760c82eb1599",
}


def _sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def url_body(source):
    found = re.search(r"\n    public func url\(scheme: String\) -> URL\? \{\n(.*?)\n    \}\n", source, re.S)
    if not found:
        raise swift_data.SwiftShapeChanged("DeepLink.url(scheme:) not found")
    return found.group(1)


def fingerprints(root):
    return {"DeepLinkExport.swift": _sha(swift_data.read(root, EXPORT)),
            "DeepLink.url": _sha(url_body(swift_data.read(root, DEEPLINK)))}


def _constants(source):
    def one(pattern, what):
        found = re.search(pattern, source)
        if not found:
            raise swift_data.SwiftShapeChanged("DeepLink.%s not found" % what)
        return found.groups()
    c = {}
    c["resourceHexDigits"] = int(one(r"static let resourceHexDigits = (\d+)\n", "resourceHexDigits")[0])
    for name in ("tokenLengths", "agentSessionLengths", "shortTokenLengths"):
        low, high = one(r"static let %s = (\d+)\.\.\.(\d+)\n" % name, name)
        c[name] = (int(low), int(high))
    for name in ("turnFragmentPrefix", "hostHintKey", "nameHintKey", "messageKey", "authCallbackHost"):
        c[name] = swift_data.swift_literal(one(r"static let %s = %s\n" % (name, swift_data.STRING), name)[0])
    return c


def _schemes(test):
    block = re.search(r"static var export: DeepLinkExport \{(.*?)\n    \}\n", test, re.S)
    stated = re.search(r"#expect\(Self\.export\.schemes\.map\(\\\.scheme\) == \[(.*?)\]\)", test)
    if not block or not stated:
        raise swift_data.SwiftShapeChanged("LinkExportTests.export or its scheme list not found")
    rows = []
    for chunk in block.group(1).split(".init(")[1:]:
        found = re.match(r"build: " + swift_data.STRING + r", bundleID: (nil|" + swift_data.STRING + r"), scheme: ", chunk)
        if not found:
            raise swift_data.SwiftShapeChanged("LinkExportTests.export row %r has a new shape" % chunk[:60])
        tag = re.search(r"exampleTag: " + swift_data.STRING + r"\)", chunk)
        rows.append({"build": swift_data.swift_literal(found.group(1)),
                     "bundle_id": found.group(3), "example_tag": tag.group(1) if tag else None})
    schemes = [swift_data.swift_literal(s) for s in re.findall(swift_data.STRING, stated.group(1))]
    if len(rows) != len(schemes):
        raise swift_data.SwiftShapeChanged("LinkExportTests.export has %d builds, the test states %d schemes"
                                           % (len(rows), len(schemes)))
    for row, scheme in zip(rows, schemes):
        row["scheme"] = scheme
    return rows


def json_text(root):
    got = fingerprints(root)
    for name, want in FINGERPRINTS.items():
        if got[name] != want:
            raise swift_data.SwiftShapeChanged("%s changed since links.py mirrored it (sha256 %s); "
                                               "port the change and update FINGERPRINTS" % (name, got[name]))
    c = _constants(swift_data.read(root, DEEPLINK))
    builds = _schemes(swift_data.read(root, TEST))
    scheme = next((b["scheme"] for b in builds if b["build"] == "release"), None) or "cmux"
    hexd = "0123456789abcdef0123456789abcdef"
    session = "0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d"
    tok, ses, short = c["tokenLengths"], c["agentSessionLengths"], c["shortTokenLengths"]
    resource_rule = "<prefix> + %d lowercase hex digits [0-9a-f]" % c["resourceHexDigits"]
    token_rule = "%d to %d ASCII letters, digits, '-', '_' or '.'" % tok
    agent_session_rule = "%d to %d ASCII letters, digits, '-', '_', '.', or ':'" % ses
    base = scheme + "://"
    agent = base + "agent/claude/" + session
    kinds = [
        {"kind": "workspace", "id_prefix": "ws_", "id_rule": resource_rule, "example": base + "workspace/ws_" + hexd},
        {"kind": "pane", "id_prefix": "pane_", "id_rule": resource_rule, "example": base + "pane/pane_" + hexd,
         "opens": "the pane's selected tab"},
        {"kind": "tab", "id_prefix": "tab_", "id_rule": resource_rule, "example": base + "tab/tab_" + hexd},
        {"kind": "session", "id_rule": "an acpmux session id: " + token_rule,
         "turn": "optional fragment #%s<turnId>; the turn id follows the same rule" % c["turnFragmentPrefix"],
         "example": base + "session/ses-01.example_a",
         "example_with_turn": base + "session/ses-01.example_a#" + c["turnFragmentPrefix"] + "turn_7"},
        {"kind": "agent", "path": "agent/<harness>/<session>",
         "id_rule": "harness: an acpmux harness name, %d to %d lowercase ASCII letters, digits or '-'; "
                    "session: the harness's own session id, %s" % (short[0], short[1], agent_session_rule),
         "hints": "optional ?%s=<machine name>&%s=<agent name>, for display only: %d to %d characters of the "
                  "session id rule; a malformed hint is dropped" % (c["hostHintKey"], c["nameHintKey"], short[0], short[1]),
         "message": "optional ?%s=<harness message id>, the session's own id for one message (%s): the chat scrolls "
                    "to it and marks it, and leaves the view where it is when its transcript has no such message. "
                    "A malformed or repeated one is dropped, never the link" % (c["messageKey"], token_rule),
         "schema": "schemas/deeplinks/agent-link.json states these parameters and their vectors for every emitter "
                   "and parser (cmux.com/deeplink/agent writes links by it)",
         "opens": "only a tab this app already shows the session in (the chat tab that adopted it, else the terminal "
                  "running it); it never starts, resumes or connects to anything",
         "example": agent,
         "example_with_hints": "%s?%s=build-mac&%s=Lanternfish" % (agent, c["hostHintKey"], c["nameHintKey"]),
         "example_with_message": "%s?%s=msg_01hq9f4c7k" % (agent, c["messageKey"])},
    ]
    schemes = []
    for b in builds:
        row = {"build": b["build"], "scheme": b["scheme"]}
        if b["bundle_id"] is not None:
            row["bundle_id"] = swift_data.swift_literal(b["bundle_id"])
        if b["example_tag"] is not None:
            row["example_tag"] = swift_data.swift_literal(b["example_tag"])
            row["rule"] = "cmux-dev-<tag>, the tag lowercased, runs of [a-z0-9] joined by single hyphens"
        schemes.append(row)
    root_doc = {
        "description": "cmux-next object links (Copy Workspace/Pane/Tab Link, agent chat sessions, outside agent "
                       "sessions), generated from CmuxNextActions/DeepLink (DeepLink.url) and "
                       "CloudConfiguration.callbackScheme. Do not edit: CMUX_UPDATE_ACTION_SURFACES=1 swift test "
                       "--filter LinkExportTests rewrites it.",
        "shape": "<scheme>://<kind>/<id>[?machine=machine_<%d hex>][#%s<turnId>, session only]"
                 % (c["resourceHexDigits"], c["turnFragmentPrefix"]),
        "schemes": schemes,
        "target_scheme": scheme,
        "target_scheme_rule": "A client that is not a shipping cmux build writes the release scheme, so the link "
                              "opens the user's installed cmux.",
        "kinds": kinds,
        "machine": "optional ?machine=machine_<%d hex>: the machine the target lives on (a hint; ids are globally "
                   "unique)" % c["resourceHexDigits"],
        "ignored": "every other query parameter is ignored, so a link never carries a command",
        "agent_tab": "Copy Tab Link on an agent chat tab writes its chat's session link (kind session, no turn), "
                     "not a tab link; a new chat with no session has no link",
        "not_links": ["%s://%s is the sign-in callback, never a link" % (scheme, c["authCallbackHost"])],
    }
    # JSONSerialization [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]: the same
    # `"key" : value` layout DeterministicJSON writes (no empty containers here).
    return djson.dumps(root_doc, pretty=True) + "\n"


def files(root):
    return {OUT: json_text(root)}
