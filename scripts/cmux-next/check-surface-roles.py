#!/usr/bin/env python3
"""Check that the Swift and CSS copies of the overlay surface roles match their one source (Leo:
"I don't like the non-glassness"; the standing rule: Glass, never opaque).

The one source is schemas/surface-roles/surface-roles.json: every popover, menu, card, toast, sheet
and tooltip is one of its roles, with its tone (the theme's glass tint or the shared neutral glass),
veil (gray, or the theme's surface with veilTint "theme"), rim, corner depth (native) and web radius, shadow and Reduce Transparency fallback. Two hand-kept copies follow it: the
app's (CmuxNextDesign/FloatingGlass/SurfaceRole.swift: `SurfaceRole`, and the neutral looks
`FloatingGlassStyle.toast`, `.dialog` and `.card`) and the webviews' (the surface-roles block of
webviews/src/ui/glass/glass.css: `--surface-<role>-*` and `--surface-near-opaque`). This script
writes nothing (no committed generated files): it fails when a copy differs from what the JSON
says and prints the text the copy should have.

    python3 scripts/cmux-next/check-surface-roles.py           # exit 1 when a copy drifted
    python3 scripts/cmux-next/check-surface-roles.py --print   # print both copies as the JSON says
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SOURCE = "schemas/surface-roles/surface-roles.json"
CSS_FILE = "webviews/src/ui/glass/glass.css"
SWIFT_FILE = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/FloatingGlass/SurfaceRole.swift"
DESIGN_SCALE = "schemas/design-scale/design-scale.json"
TRANSIENT_FILE = "Packages/Shared/CmuxTheme/Sources/CmuxTheme/TransientMaterial.swift"
# What this check reads. scripts/web_lint_prepush.py runs it alone when a push touches one (declared_inputs()).
INPUTS = (SOURCE, DESIGN_SCALE, CSS_FILE, SWIFT_FILE, TRANSIENT_FILE)
BEGIN = "/* surface-roles:begin. Follows " + SOURCE + " (scripts/cmux-next/check-surface-roles.py checks it). */"
END = "/* surface-roles:end */"
# The neutral glass's gray levels (FloatingGlassStyle.look): dark veil, light veil. The web reads them
# as the design scale's glass material tokens (--ds-material-neutral-*, --ds-material-rim-*), so every
# neutral role mixes the one material at its own opacity and names no color of its own.
DARK_GRAY, LIGHT_GRAY = 0.11, 0.99
FIELDS = {"name", "for", "tone", "cornerDepth", "webRadius", "castsShadow", "reduceTransparency"}
NEUTRAL_FIELDS = FIELDS | {"style", "veil", "rim"}
# A neutral role may tint its veil with the theme's surface ("theme") instead of the gray ("gray", the default).
VEIL_TINTS = ("gray", "theme")


def load():
    with open(os.path.join(ROOT, SOURCE)) as handle:
        data = json.load(handle)
    assert 0 < data["nearOpaque"] < 1, data["nearOpaque"]
    names = [role["name"] for role in data["roles"]]
    assert len(names) == len(set(names)), "one entry per role"
    styles = []
    for role in data["roles"]:
        assert role["name"].isidentifier(), role["name"]
        # A native corner is a level of the one concentric corner rule, never a literal radius.
        assert isinstance(role["cornerDepth"], int) and role["cornerDepth"] >= 0, role
        if role["tone"] == "neutral":
            assert set(role) - {"veilTint"} == NEUTRAL_FIELDS, role
            assert role.get("veilTint", "gray") in VEIL_TINTS, role
            assert role["style"].isidentifier(), role
            styles.append(role["style"])
            for appearance in ("dark", "light"):
                veil = role["veil"][appearance]
                # A veil is a tint over the glass, never a fill that hides it.
                assert 0 < veil < data["nearOpaque"], (role["name"], appearance, veil)
                top, bottom = role["rim"][appearance]
                assert 0 <= bottom < top <= 1, (role["name"], appearance, role["rim"])
        else:
            assert role["tone"] == "theme" and set(role) == FIELDS, role
    assert len(styles) == len(set(styles)), "one role per neutral style"
    with open(os.path.join(ROOT, DESIGN_SCALE)) as handle:
        scale = json.load(handle)
    transient = scale["transientMaterial"]
    # This guard already needs native source. Keep web generation independent
    # of platform files omitted from gallery and other web-only checkouts.
    with open(os.path.join(ROOT, TRANSIENT_FILE)) as handle:
        native = handle.read()
    tokens = dict(transient)
    tokens.update({key: scale["glassMaterial"][key] for key in ("neutralDark", "neutralLight")})
    for key, value in tokens.items():
        if not isinstance(value, (int, float)):
            continue
        match = re.search(r"public let " + re.escape(key) + r": Double = ([0-9.]+)", native)
        assert match and float(match[1]) == value, f"{TRANSIENT_FILE} {key} must match the design scale"
    toast = next(role for role in data["roles"] if role["name"] == "toast")
    for appearance in ("dark", "light"):
        assert toast["veil"][appearance] == transient[appearance + "VeilAlpha"], "toast and transient veil differ"
        assert toast["rim"][appearance] == [transient[appearance + "RimTop"], transient[appearance + "RimBottom"]], "toast and transient rim differ"
    return data


def takes_theme_tint(role):
    return role.get("veilTint", "gray") == "theme"


def doc(text):
    return text[0].upper() + text[1:]


def num(value):
    return "%g" % value


def swift(data):
    cases = "\n".join("    /// %s.\n    case %s" % (doc(role["for"]), role["name"]) for role in data["roles"])
    neutral = [role for role in data["roles"] if role["tone"] == "neutral"]
    style_cases = "\n".join("        case .%s: return .%s" % (role["name"], role["style"]) for role in neutral)
    depth_cases = "\n".join("        case .%s: return %d" % (role["name"], role["cornerDepth"]) for role in data["roles"])
    shadow_cases = ", ".join("." + role["name"] for role in data["roles"] if role["castsShadow"])
    fallback_cases = "\n".join(
        '        case .%s: return "%s"' % (role["name"], role["reduceTransparency"]) for role in data["roles"]
    )
    looks = "\n".join(
        "    /// Toasts share the transient material without changing the held chat appearance.\n    nonisolated public static let toast = FloatingGlassStyle.transient"
        if role["name"] == "toast" else
        "    /// %s.\n"
        "    nonisolated public static let %s = FloatingGlassStyle(cornerDepth: %d, darkVeilAlpha: %s, lightVeilAlpha: %s,\n"
        "                                                         darkRim: (%s, %s), lightRim: (%s, %s), castsShadow: %s%s)"
        % (
            doc(role["for"]),
            role["style"],
            role["cornerDepth"],
            num(role["veil"]["dark"]),
            num(role["veil"]["light"]),
            num(role["rim"]["dark"][0]),
            num(role["rim"]["dark"][1]),
            num(role["rim"]["light"][0]),
            num(role["rim"]["light"][1]),
            "true" if role["castsShadow"] else "false",
            ",\n                                                         veilTakesThemeTint: true" if takes_theme_tint(role) else "",
        )
        for role in neutral
    )
    return """// Follows {src}: change the JSON first, then this copy;
// scripts/cmux-next/check-surface-roles.py fails when the two differ.

public import CoreGraphics

/// The overlay surface roles: every popover, menu, card, toast, sheet and tooltip is one of these,
/// native and web (the webviews' `--surface-<role>-*`). Glass, never opaque: each role is glass, and
/// its text reads through the blur, tint and contrast inside the glass, never an opaque fill.
/// Reduce Transparency is the one opaque fallback (``OverlayMaterial/opaque``). Make a role's surface
/// with `Glass.makeSurface(_:content:)`.
public nonisolated enum SurfaceRole: String, CaseIterable, Sendable {{
{cases}

    /// The share of what is behind it at or above which a fill on an overlay reads as solid:
    /// check-overlay-glass.py and check-glass-never-opaque.ts fail one outside their allowlists.
    public static let nearOpaque: Double = {near}

    /// The shared neutral glass the role draws; nil for a role on the theme's glass tint.
    public var neutralStyle: FloatingGlassStyle? {{
        switch self {{
{style_cases}
        default: return nil
        }}
    }}

    /// How the role tints its glass: the theme's tint, or its neutral glass with the rim.
    public var tone: OverlayTone {{
        neutralStyle.map {{ .neutralGlass($0) }} ?? .theme
    }}

    /// How many levels inside the one corner radius the role's corner is: 0 is the outer radius
    /// (a top-level surface); `cornerRadius` (SurfaceRole+CornerRadius.swift) resolves it.
    public var cornerDepth: Int {{
        switch self {{
{depth_cases}
        }}
    }}

    /// Whether the role casts the popups' soft shadow (a floating panel); a card on the sidebar does not.
    public var castsShadow: Bool {{
        [{shadow_cases}].contains(self)
    }}

    /// What the role draws under Reduce Transparency, its one opaque path.
    public var reduceTransparencyFallback: String {{
        switch self {{
{fallback_cases}
        }}
    }}
}}

extension FloatingGlassStyle {{
{looks}
}}
""".format(
        src=SOURCE,
        cases=cases,
        near=num(data["nearOpaque"]),
        style_cases=style_cases,
        depth_cases=depth_cases,
        shadow_cases=shadow_cases,
        fallback_cases=fallback_cases,
        looks=looks,
    )


def material():
    # The design scale's glass material must be the gray levels the native neutral looks draw.
    with open(os.path.join(ROOT, DESIGN_SCALE)) as handle:
        glass = json.load(handle)["glassMaterial"]
    assert (glass["neutralLight"], glass["neutralDark"], glass["rimLit"], glass["rimShade"]) == (
        LIGHT_GRAY, DARK_GRAY, 1, 0), "%s glassMaterial differs from FloatingGlassStyle.look's grays" % DESIGN_SCALE
    return {LIGHT_GRAY: "--ds-material-neutral-light", DARK_GRAY: "--ds-material-neutral-dark", 1: "--ds-material-rim-lit",
            0: "--ds-material-rim-shade"}


def gray(white, alpha):
    # The material's token at the role's opacity (color-mix with transparent is the gray at that alpha).
    return "color-mix(in srgb, var(%s) %s%%, transparent)" % (material()[white], num(round(alpha * 100, 2)))


def theme_veil(alpha):
    # The theme's surface (--glass-surface, the color the popovers' tint mixes) at the veil's opacity.
    return "color-mix(in srgb, var(--glass-surface) %s%%, transparent)" % num(round(alpha * 100, 2))


def css_block(data):
    lines = [
        BEGIN,
        "/* The overlay surface roles (CmuxNextDesign SurfaceRole): a card, toast or sheet reads its radius,",
        "   veil and rim here; popovers and menus are .ui-popup.ui-glass (--ui-popup-radius, the tint above).",
        "   Glass, never opaque: a fill on an overlay covers less than --surface-near-opaque; Reduce",
        "   Transparency is the one opaque path (--glass-opaque). A neutral role's veil and rims are one",
        "   material, the design scale's (--ds-material-neutral-*, --ds-material-rim-*), at the role's opacities. */",
        ":root {",
        "  --surface-near-opaque: %s%%;" % num(round(data["nearOpaque"] * 100, 2)),
    ]
    for role in data["roles"]:
        prefix = "  --surface-%s" % role["name"]
        if role["webRadius"] is not None:
            lines.append("%s-radius: %spx; /* %s */" % (prefix, num(role["webRadius"]), role["for"]))
        if role["tone"] == "neutral":
            if takes_theme_tint(role):
                lines.append("%s-veil: light-dark(%s, %s);" % (
                    prefix, theme_veil(role["veil"]["light"]), theme_veil(role["veil"]["dark"])))
            else:
                lines.append("%s-veil: light-dark(%s, %s);" % (
                    prefix, gray(LIGHT_GRAY, role["veil"]["light"]), gray(DARK_GRAY, role["veil"]["dark"])))
            light_top, light_bottom = role["rim"]["light"]
            dark_top, dark_bottom = role["rim"]["dark"]
            lines.append("%s-rim-top: light-dark(%s, %s);" % (prefix, gray(1, light_top), gray(1, dark_top)))
            lines.append("%s-rim-bottom: light-dark(%s, %s);" % (prefix, gray(0, light_bottom), gray(1, dark_bottom)))
    lines += ["}", END]
    return "\n".join(lines)


def css(current, data):
    if BEGIN in current:
        start, end = current.index(BEGIN), current.index(END) + len(END)
        return current[:start] + css_block(data) + current[end:]
    return current.rstrip("\n") + "\n\n" + css_block(data) + "\n"


def main():
    data = load()
    with open(os.path.join(ROOT, CSS_FILE)) as handle:
        current_css = handle.read()
    wanted = {CSS_FILE: css(current_css, data), SWIFT_FILE: swift(data)}
    if "--print" in sys.argv[1:]:
        print("== " + SWIFT_FILE + "\n" + wanted[SWIFT_FILE])
        print("== " + CSS_FILE + " (its surface-roles block)\n" + css_block(data))
        return
    drifted = []
    for path, text in wanted.items():
        full = os.path.join(ROOT, path)
        old = open(full).read() if os.path.exists(full) else None
        if old != text:
            drifted.append(path)
    if drifted:
        print("surface role copies differ from %s: %s\nrun python3 scripts/cmux-next/check-surface-roles.py --print "
              "for the text they should have" % (SOURCE, ", ".join(drifted)))
        sys.exit(1)
    print("surface roles: copies match " + SOURCE)


if __name__ == "__main__":
    main()
