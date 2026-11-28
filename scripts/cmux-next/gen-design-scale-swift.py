#!/usr/bin/env python3
"""Write the Swift copy of the one design scale (schemas/design-scale/design-scale.json), so the native
chrome and the webviews read the same spacing, control heights, icon sizes, radii, glass levels and
elevations (Leo 2026-11-25: "anything that's just variable swaps and consistency in component
families is good. hey, it's like... we're making our own component library").

webviews/scripts/pages/gen-design-scale.mjs writes the web copies (--ds-*, the Tailwind theme, the
token sheet). This script writes the Swift one, `DesignScale` (DesignScale.generated.swift), and
`DesignTokens` (CmuxNextDesignTokens/DesignTokens.swift) forwards its public names to it.

The Swift file is not in git (a committed generated file is refused by scripts/ci/generated-files.json):
the DesignScalePlugin build-tool plugin (Packages/macOS/CmuxNext/Plugins/DesignScalePlugin) runs this
script with --swift-out into its work directory on every build, like SettingsSchemaPlugin. A file whose
text is unchanged is not rewritten, so an incremental build recompiles nothing.

NATIVE_OVERRIDES holds the few native values that differ from the JSON today. Each keeps the Swift
value the app had before this generator, so nothing renders differently; the design scale's owner
settles them (move the JSON, or drop the override and let the app follow it). --check fails on an
override that the JSON already equals, so a settled one is removed, not kept.

    python3 scripts/cmux-next/gen-design-scale-swift.py --check            # exit 1 on a bad scale or a stale override
    python3 scripts/cmux-next/gen-design-scale-swift.py --swift-out DIR    # write the Swift into DIR
"""
import json, os, re, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SOURCE = "schemas/design-scale/design-scale.json"
SWIFT_NAME = "DesignScale.generated.swift"

# Native values that differ from the JSON today: name -> (Swift value, the JSON value it differs from, why).
NATIVE_OVERRIDES = {
    "radiusControl": (
        6,
        lambda data: named_radius_px(data, "control"),
        "namedRadii `control` is the tab's corner, var(--cmux-button-radius, 8px); the native "
        "`DesignTokens.radiusControl` has been 6 (radii `md`). Nothing native reads it yet.",
    ),
    "glassPlainTint": (
        0.6,
        lambda data: glass(data, "chrome")["tint"] / 100,
        "the native plain glass tint has been 60%; the JSON's docked `chrome` level is 62%. "
        "Nothing native reads it yet.",
    ),
}


def load():
    with open(os.path.join(ROOT, SOURCE)) as handle:
        data = json.load(handle)
    steps = data["spacing"]["steps"]
    assert [s["px"] for s in steps] == sorted({s["px"] for s in steps}), "spacing runs small to large, once each"
    for group in ("controls", "icons", "radii"):
        for item in data[group]:
            assert isinstance(item["px"], (int, float)) and item["px"] > 0, (group, item)
    for level in data["glass"]:
        assert level["kind"] in ("level", "mode"), level
        assert 0 < level["tint"] < 100, level
        blur_and_saturation(level)
    for shadow in data["elevation"]:
        geometry(shadow)
        assert 0 < shadow["light"] < 100 and 0 < shadow["dark"] < 100, shadow
    return data


def glass(data, name):
    return next(level for level in data["glass"] if level["name"] == name)


def named_radius_px(data, name):
    """A named radius in px: its `px`, else the px fallback of its `var(...)`, else None."""
    item = next(r for r in data["namedRadii"] if r["name"] == name)
    if "px" in item:
        return item["px"]
    match = re.search(r",\s*([0-9.]+)px\)$", item.get("var", ""))
    return float(match.group(1)) if match else None


def blur_and_saturation(level):
    match = re.fullmatch(r"blur\(([0-9.]+)px\) saturate\(([0-9.]+)\)", level["blur"])
    assert match, "glass %s's blur is blur(<px>) saturate(<n>): %r" % (level["name"], level["blur"])
    return float(match.group(1)), float(match.group(2))


def geometry(shadow):
    match = re.fullmatch(r"(-?[0-9.]+)(?:px)? (-?[0-9.]+)px ([0-9.]+)px", shadow["geometry"])
    assert match, "elevation %s's geometry is <x> <y>px <blur>px: %r" % (shadow["name"], shadow["geometry"])
    return tuple(float(v) for v in match.groups())


def num(value):
    """A Swift CGFloat literal: 4, 0.62, 2.5 (no float noise: percentages divide exactly as Python prints them)."""
    value = float(value)
    return str(int(value)) if value.is_integer() else repr(value)


def ident(prefix, name):
    """`radius` + `2xl` -> radius2xl; `glass` + `chrome` -> glassChrome."""
    return prefix + name[:1].upper() + name[1:] if name[:1].isalpha() else prefix + name


def doc(text):
    return "    /// " + text[:1].upper() + text[1:].rstrip(".") + "."


def stale_overrides(data):
    """Overrides the JSON already equals: settled, so the override goes."""
    return [name for name, (value, json_value, _) in NATIVE_OVERRIDES.items() if json_value(data) == value]


def swift(data):
    out = []

    def let(name, value, comment=None):
        if comment:
            out.append(doc(comment))
        out.append("    public static let %s: CGFloat = %s" % (name, num(value)))

    out.append("    // Spacing: the grid steps (tokens.md), px at interface scale 1.")
    for step in data["spacing"]["steps"]:
        let(ident("space", step["name"]), step["px"])
    out.append("    /// The layout steps past the spacing scale.")
    out.append("    public static let spaceLayout: [CGFloat] = [%s]" % ", ".join(num(v) for v in data["spacing"]["layout"]))
    out.append("")
    out.append("    // Control heights.")
    for item in data["controls"]:
        let(ident("control", item["name"]), item["px"], item.get("for"))
    out.append("")
    out.append("    // Icon sizes.")
    for item in data["icons"]:
        let(ident("icon", item["name"]), item["px"], item.get("for"))
    out.append("")
    out.append("    // Radii: the steps, then the named radii that are a number (a `var(...)` one is the host's).")
    for item in data["radii"]:
        let(ident("radius", item["name"]), item["px"], item.get("for"))
    for item in data["namedRadii"]:
        if "px" in item:
            let(ident("radius", item["name"]), item["px"], item.get("for"))
    out.append("")
    out.append("    // Glass: each level's and mode's tint (0...1 of the surface), dark tint, blur radius and saturation.")
    for level in data["glass"]:
        base = ident("glass", level["name"])
        blur, saturation = blur_and_saturation(level)
        let(base + "Tint", level["tint"] / 100, "%s %s: %s" % (level["name"], level["kind"], level["for"].split(":")[0].split(";")[0]))
        for key in ("darkTint", "artTint", "veil"):
            if key in level:
                let(base + key[:1].upper() + key[1:], level[key] / 100)
        let(base + "Blur", blur)
        let(base + "Saturation", saturation)
    out.append("")
    out.append("    // Elevations: the shadow's offset and blur, and its opacity (0...1) in light and dark.")
    for shadow in data["elevation"]:
        base = ident("elevation", shadow["name"])
        x, y, blur = geometry(shadow)
        let(base + "OffsetX", x, shadow["for"])
        let(base + "OffsetY", y)
        let(base + "Blur", blur)
        let(base + "LightOpacity", shadow["light"] / 100)
        let(base + "DarkOpacity", shadow["dark"] / 100)
    out.append("")
    out.append("    /// Native values that differ from the JSON today (NATIVE_OVERRIDES in the generator): each keeps")
    out.append("    /// the app's value until the design scale settles it.")
    out.append("    public nonisolated enum NativeOverride {")
    for name, (value, json_value, why) in NATIVE_OVERRIDES.items():
        out.append("        /// JSON: %s. %s" % (num(json_value(data)), why[:1].upper() + why[1:]))
        out.append("        public static let %s: CGFloat = %s" % (name, num(value)))
    out.append("    }")
    body = "\n".join(out)
    return """// GENERATED by scripts/cmux-next/gen-design-scale-swift.py from
// {src}. Do not edit; edit the JSON and rebuild.

public import CoreGraphics

/// The one design scale of cmux NEXT, shared with the webviews' `--ds-*` tokens (gen-design-scale.mjs).
/// `DesignTokens` forwards its names here.
public nonisolated enum DesignScale {{
{body}
}}
""".format(src=SOURCE, body=body)


def parse_args(argv):
    check, swift_out, rest = False, None, list(argv)
    while rest:
        arg = rest.pop(0)
        if arg == "--check":
            check = True
        elif arg == "--swift-out" and rest:
            swift_out = os.path.abspath(rest.pop(0))
        elif arg.startswith("--swift-out="):
            swift_out = os.path.abspath(arg.split("=", 1)[1])
        else:
            print("usage: gen-design-scale-swift.py [--check] [--swift-out DIR]", file=sys.stderr)
            sys.exit(2)
    return check, swift_out


def main(argv=None):
    check, swift_out = parse_args(sys.argv[1:] if argv is None else argv)
    if swift_out is None and not check:
        print("gen-design-scale-swift.py: the build generates the Swift (DesignScalePlugin); "
              "run --check, or --swift-out DIR to see it", file=sys.stderr)
        return 2
    data = load()
    text = swift(data)
    if check:
        stale = stale_overrides(data)
        if stale:
            print("%s now equals the native value of %s: drop the override from NATIVE_OVERRIDES in "
                  "scripts/cmux-next/gen-design-scale-swift.py" % (SOURCE, ", ".join(stale)))
            return 1
        # The text must also be valid enough to write: every identifier a Swift one.
        for name in re.findall(r"static let (\S+):", text):
            assert re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name), name
    if swift_out is not None:
        os.makedirs(swift_out, exist_ok=True)
        path = os.path.join(swift_out, SWIFT_NAME)
        current = open(path).read() if os.path.exists(path) else None
        if current != text:
            if check:
                print("%s is stale; rebuild" % path)
                return 1
            with tempfile.NamedTemporaryFile("w", dir=swift_out, delete=False) as handle:
                handle.write(text)
            os.replace(handle.name, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
