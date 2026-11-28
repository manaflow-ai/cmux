"""docs/mdm without Swift: ManagedPreferencesManifest(+Docs).swift in Python.

Entries are the settings export's rows that cmux-next reads (`isShownInCmuxNext`), then
ManagedPreferences.policyKeys, read from ManagedPreferences.swift. The property lists are written
the way Foundation's PropertyListSerialization (.xml) writes them: keys in code point order, tab
indentation, `<array/>` and `<dict/>` for empty containers, reals as CoreFoundation prints them.
"""
from __future__ import annotations

import datetime
import re

import djson
import swift_data

MANAGED = swift_data.PKG + "/CmuxNextSettings/Managed"
STRING = swift_data.STRING


def _lit(text):
    return swift_data.swift_literal(text)


class Constants:
    def __init__(self, root):
        manifest = swift_data.read(root, MANAGED + "/ManagedPreferencesManifest.swift")
        prefs = swift_data.read(root, MANAGED + "/ManagedPreferences.swift")

        def one(pattern, source, what):
            found = re.search(pattern, source, re.S)
            if not found:
                raise swift_data.SwiftShapeChanged("%s not found" % what)
            return found.group(1)
        self.title = _lit(one(r"public static let title = " + STRING, manifest, "ManagedPreferencesManifest.title"))
        self.summary = _lit(one(r"public static let summary = " + STRING, manifest, "ManagedPreferencesManifest.summary"))
        self.version = int(one(r"public static let version = (\d+)", manifest, "ManagedPreferencesManifest.version"))
        seconds = int(one(r"lastModified = Date\(timeIntervalSince1970: ([\d_]+)\)", manifest, "lastModified").replace("_", ""))
        self.last_modified = datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.domain = _lit(one(r"public static let domain = " + STRING, prefs, "ManagedPreferences.domain"))
        self.legacy_domain = _lit(one(r"public static let legacyDomain = " + STRING, prefs, "ManagedPreferences.legacyDomain"))
        body = one(r"public static let policyKeys: \[ManagedPolicyKey\] = \[(.*?)\n    \]\n", prefs, "ManagedPreferences.policyKeys")
        self.policy_keys = []
        pattern = (r"ManagedPolicyKey\(" + STRING + r",\s*type:\s*\.(\w+)(?:\(\[(.*?)\]\))?,\s*help:\s*" + STRING + r"\)")
        for found in re.finditer(pattern, body, re.S):
            values = [_lit(v) for v in re.findall(STRING, found.group(3) or "")]
            self.policy_keys.append({"name": _lit(found.group(1)), "type": found.group(2), "values": values,
                                     "help": _lit(found.group(4))})
        if len(self.policy_keys) != body.count("ManagedPolicyKey("):
            raise swift_data.SwiftShapeChanged("a ManagedPolicyKey in policyKeys has an unknown shape")
        # The texts the Swift writes inline: they must still be what this file writes.
        docs = swift_data.read(root, MANAGED + "/ManagedPreferencesManifest+Docs.swift")
        for needle in ("5B0C4E42-7D8A-4C55-9C3E-2D6F4A1B9E01", "5B0C4E42-7D8A-4C55-9C3E-2D6F4A1B9E00",
                       "entries.prefix(3)", '"# cmux managed preferences"'):
            if needle not in docs:
                raise swift_data.SwiftShapeChanged("ManagedPreferencesManifest+Docs.swift changed (%s)" % needle)
        self.docs_lines = _markdown_header(docs)


def _markdown_header(docs):
    found = re.search(r"var lines = \[\n(.*?)\n        \]\n", docs, re.S)
    if not found:
        raise swift_data.SwiftShapeChanged("markdown() header lines not found")
    out = []
    for line in found.group(1).splitlines():
        literal = re.match(r"\s*" + STRING + r",?\s*$", line)
        if not literal:
            raise swift_data.SwiftShapeChanged("markdown() header line %r" % line.strip())
        out.append(_lit(literal.group(1)))
    return out


def _interpolate(text, constants):
    text = text.replace("\\(ManagedPreferences.domain)", constants.domain)
    text = text.replace("\\(ManagedPreferences.legacyDomain)", constants.legacy_domain)
    if "\\(" in text:
        raise swift_data.SwiftShapeChanged("unknown interpolation in %r" % text)
    return text


# Entries ------------------------------------------------------------------------------------------


def _int(value):
    return int(value)  # Swift Int(Double) truncates toward zero, as int() does


def entries(document, constants):
    out = []
    for row in document["rows"]:
        if "cmux-next" not in row["consumers"]:
            continue
        help_ = row["help"]["text"] if row["help"] else ""
        more = " " if help_ else ""
        kind = row["kind"]
        entry = {"name": row["key"], "title": row["title"]["text"], "help": help_, "type": "string",
                 "choices": [], "range": None, "default": row["default"], "members": [], "shape": None}
        if kind == "choice":
            entry["choices"] = [c["value"] for c in row["choices"]]
        elif kind == "choice_or_number":
            entry["choices"] = [c["value"] for c in row["choices"]]
            entry["help"] = help_ + "%sAlso accepts a number from %d to %d in a raw profile." % (
                more, _int(row["range"]["min"]), _int(row["range"]["max"]))
        elif kind == "choice_or_url":
            entry["choices"] = [c["value"] for c in row["choices"]]
            entry["help"] = help_ + '%sAlso accepts a dictionary {"%s": "http(s)://host[:port]"} in a raw profile.' % (
                more, row["url_key"])
        elif kind == "toggle":
            entry["type"] = "boolean"
        elif kind == "number":
            entry["type"] = "real"
            entry["range"] = (float(row["range"]["min"]), float(row["range"]["max"]))
        elif kind in ("color", "sound", "url", "theme", "font_family", "text"):
            pass
        elif kind in ("host_list", "folder_list", "number_list"):
            entry["type"] = "array"
        elif kind == "string_list":
            entry["type"] = "array"
            entry["choices"] = [c["value"] for c in row.get("choices", [])]
        elif kind == "time_range":
            entry["type"] = "dictionary"
            entry["members"] = ["start", "end"]
        elif kind in ("string_map", "sound_rules"):
            entry["type"] = "dictionary"
        elif kind == "json":
            entry["help"] = help_ + "%sNested; see `cmux settings schema` for its shape." % more
            entry["type"] = "dictionary" if row["shape"].get("type") == "object" else "array"
            entry["shape"] = row["shape"]
        else:
            raise swift_data.SwiftShapeChanged("setting kind %r has no MDM entry here" % kind)
        out.append(entry)
    for key in constants.policy_keys:
        types = {"string": "string", "boolean": "boolean", "choice": "string", "stringArray": "array"}
        if key["type"] not in types:
            raise swift_data.SwiftShapeChanged("policy key type %r" % key["type"])
        out.append({"name": key["name"], "title": key["name"], "help": key["help"], "type": types[key["type"]],
                    "choices": key["values"], "range": None, "default": None, "members": [], "shape": None})
    return out


class Real(float):
    """A Double in a [String: Any]: always <real>, never <integer>."""


def property_list(value):
    """ManagedPreferencesManifest.propertyList: nil drops, whole numbers become Int."""
    if value is None:
        return None
    if isinstance(value, bool) or isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        if float(value) == round(value) and abs(value) < 1e15:
            return int(value)
        return Real(value)
    if isinstance(value, list):
        return [v for v in (property_list(item) for item in value) if v is not None]
    if isinstance(value, dict):
        return {k: v for k, v in ((k, property_list(item)) for k, item in value.items()) if v is not None}
    raise TypeError(type(value).__name__)


# Property list XML (Foundation's writer) ----------------------------------------------------------

HEADER = ('<?xml version="1.0" encoding="UTF-8"?>\n'
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
          '<plist version="1.0">\n')


class Date(str):
    pass


def _escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _real(value):
    if value == 0:
        return "0.0"
    return "%.17g" % value


def _utf16_key(key):
    return key.encode("utf-16-be")


def _plist(value, depth, out):
    tabs = "\t" * depth
    if isinstance(value, bool):
        out.append(tabs + ("<true/>" if value else "<false/>"))
    elif isinstance(value, Date):
        out.append(tabs + "<date>%s</date>" % value)
    elif isinstance(value, str):
        out.append(tabs + "<string>%s</string>" % _escape(value))
    elif isinstance(value, Real):
        out.append(tabs + "<real>%s</real>" % _real(value))
    elif isinstance(value, int):
        out.append(tabs + "<integer>%d</integer>" % value)
    elif isinstance(value, float):
        out.append(tabs + "<real>%s</real>" % _real(value))
    elif isinstance(value, (list, tuple)):
        if not value:
            out.append(tabs + "<array/>")
            return
        out.append(tabs + "<array>")
        for item in value:
            _plist(item, depth + 1, out)
        out.append(tabs + "</array>")
    elif isinstance(value, dict):
        if not value:
            out.append(tabs + "<dict/>")
            return
        out.append(tabs + "<dict>")
        for key in sorted(value, key=_utf16_key):
            out.append(tabs + "\t<key>%s</key>" % _escape(key))
            _plist(value[key], depth + 1, out)
        out.append(tabs + "</dict>")
    else:
        raise TypeError(type(value).__name__)


def plist_xml(value):
    out = []
    _plist(value, 0, out)
    return HEADER + "\n".join(out) + "\n</plist>\n"


# The five files ---------------------------------------------------------------------------------


def profile_manifest(items, constants):
    subkeys = []
    for e in items:
        key = {"pfm_name": e["name"], "pfm_title": e["title"], "pfm_type": e["type"]}
        if e["help"]:
            key["pfm_description"] = e["help"]
        value = property_list(e["default"])
        if value is not None:
            key["pfm_default"] = value
        if e["type"] == "array":
            items_type = ((e["shape"] or {}).get("items") or {}).get("type")
            item = {"pfm_name": "Item", "pfm_type": "array" if items_type == "array" else "string"}
            if e["choices"]:
                item["pfm_range_list"] = e["choices"]
            key["pfm_subkeys"] = [item]
        elif e["choices"]:
            key["pfm_range_list"] = e["choices"]
        if e["range"]:
            key["pfm_range_min"] = Real(e["range"][0])
            key["pfm_range_max"] = Real(e["range"][1])
        if e["members"]:
            key["pfm_subkeys"] = [{"pfm_name": m, "pfm_type": "string", "pfm_description": "HH:MM"} for m in e["members"]]
        subkeys.append(key)
    manifest = {
        "pfm_domain": constants.domain, "pfm_title": constants.title, "pfm_description": constants.summary,
        "pfm_format_version": 1, "pfm_version": constants.version, "pfm_last_modified": Date(constants.last_modified),
        "pfm_platforms": ["macOS"], "pfm_targets": ["user", "system"], "pfm_unique": True, "pfm_subkeys": subkeys,
    }
    return plist_xml(manifest)


def jamf_schema(items, constants):
    properties = {}
    for e in items:
        p = {"title": e["title"], "description": e["help"] if e["help"] else e["title"]}
        if isinstance(e["shape"], dict):
            for rule, value in e["shape"].items():
                converted = property_list(value)
                if converted is None:
                    p.pop(rule, None)
                else:
                    p[rule] = converted
            properties[e["name"]] = p
            continue
        if e["type"] == "boolean":
            p["type"] = "boolean"
        elif e["type"] == "string":
            p["type"] = "string"
        elif e["type"] == "real":
            p["type"] = "number"
        elif e["type"] == "array":
            p["type"] = "array"
            p["items"] = {"type": "string", "enum": e["choices"]} if e["choices"] else {"type": "string"}
        elif e["type"] == "dictionary":
            p["type"] = "object"
            p["properties"] = {m: {"type": "string", "title": m} for m in e["members"]}
        if e["type"] != "array" and e["choices"]:
            p["enum"] = e["choices"]
        if e["range"]:
            p["minimum"] = e["range"][0]
            p["maximum"] = e["range"][1]
        value = property_list(e["default"])
        if value is not None:
            p["default"] = value
        properties[e["name"]] = p
    schema = {"title": "%s (%s)" % (constants.title, constants.domain), "description": constants.summary,
              "properties": properties}
    return djson.dumps(schema, pretty=True) + "\n"


def example_keys(items):
    keys = {}
    for e in items[:3]:
        value = property_list(e["default"])
        if value is not None:
            keys[e["name"]] = value
    # ManagedPreferencesManifest.exampleKeys also sets the App Store toggle at its default.
    app_store = next((e for e in items if e["name"] == "labs.appStore"), None)
    if app_store is not None:
        value = property_list(app_store["default"])
        if value is not None:
            keys[app_store["name"]] = value
    keys["DisabledFeatures"] = []
    return keys


def example_mobileconfig(items, constants):
    payload = dict(example_keys(items))
    for key, value in (("PayloadType", constants.domain), ("PayloadVersion", 1),
                       ("PayloadIdentifier", "com.manaflow.cmux.example.settings"),
                       ("PayloadUUID", "5B0C4E42-7D8A-4C55-9C3E-2D6F4A1B9E01"), ("PayloadDisplayName", "cmux settings")):
        payload.setdefault(key, value)  # `merging { first, _ in first }`: the example key wins
    profile = {
        "PayloadType": "Configuration", "PayloadVersion": 1, "PayloadIdentifier": "com.manaflow.cmux.example",
        "PayloadUUID": "5B0C4E42-7D8A-4C55-9C3E-2D6F4A1B9E00", "PayloadDisplayName": "cmux (example)",
        "PayloadDescription": "Example managed settings for cmux. Generated from the settings catalog; see managed-preferences.md.",
        "PayloadScope": "System", "PayloadContent": [payload],
    }
    return plist_xml(profile)


def intune_preference_file(items):
    xml = plist_xml(example_keys(items))
    start = xml.find("<dict>\n")
    end = xml.rfind("</dict>\n</plist>")
    if start < 0 or end < 0:
        return xml
    body = xml[start + len("<dict>\n"):end]
    return "\n".join(line[1:] if line.startswith("\t") else line for line in body.split("\n"))


def _swift_double(value):
    """Swift's String(Double): the shortest round trip, `1e-05` style exponents."""
    text = repr(float(value))
    if "e" in text:
        mantissa, exponent = text.split("e")
        sign = "-" if exponent.startswith("-") else ""
        digits = exponent.lstrip("+-").lstrip("0") or "0"
        return "%se%s%s" % (mantissa.replace(".0", "") if mantissa.endswith(".0") else mantissa, sign,
                            digits.rjust(2, "0"))
    return text


def _format(value):
    return str(int(value)) if round(value) == value else _swift_double(value)


def compact_text(value):
    """JSONValue.compactText."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        if float(value) == round(value) and abs(value) < 1e15:
            return str(int(value))
        return _swift_double(value)
    if isinstance(value, str):
        return djson.quote(value)
    if isinstance(value, list):
        return "[" + ",".join(compact_text(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(djson.quote(k) + ":" + compact_text(value[k]) for k in sorted(value)) + "}"
    raise TypeError(type(value).__name__)


def markdown(items, constants):
    lines = [_interpolate(line, constants) for line in constants.docs_lines]
    for e in items:
        if e["choices"]:
            allowed = ", ".join("`%s`" % c for c in e["choices"])
        elif e["range"]:
            allowed = "%s to %s" % (_format(e["range"][0]), _format(e["range"][1]))
        elif e["members"]:
            allowed = ", ".join("`%s`: HH:MM" % m for m in e["members"])
        else:
            allowed = ""
        fallback = "`%s`" % compact_text(e["default"]) if e["default"] is not None else ""
        help_ = e["help"].replace("|", "\\|")
        if e["title"] == e["name"]:
            text = help_
        else:
            text = e["title"] if not help_ else "%s. %s" % (e["title"], help_)
        lines.append("| `%s` | %s | %s | %s | %s |" % (e["name"], e["type"], fallback, allowed, text))
    return "\n".join(lines) + "\n"


def files(root, document):
    """{repo path: text} of the five docs/mdm exports."""
    constants = Constants(root)
    items = entries(document, constants)
    # Keyed by file name under docs/mdm: the settings export list (scripts/cmux-next/) is the one list of the
    # exports' paths (tests/test_settings_stamp_not_committed.py), and export.py checks against it.
    names = {
        "com.manaflow.cmux.plist": profile_manifest(items, constants),
        "com.manaflow.cmux.json": jamf_schema(items, constants),
        "cmux-example.mobileconfig": example_mobileconfig(items, constants),
        "com.manaflow.cmux.intune.plist": intune_preference_file(items),
        "managed-preferences.md": markdown(items, constants),
    }
    return {"docs/mdm/" + name: text for name, text in names.items()}
