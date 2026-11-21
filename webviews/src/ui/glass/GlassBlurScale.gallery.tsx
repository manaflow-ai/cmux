// l10n-allow-file: gallery fixtures, not shipped UI.
// Three blur radii (cmuxterm-hq docs/reading/2026-11-19-glass-field-study.md, gap 3). Leo: "why can't we
// just... combine the best of both worlds and fix the real glass". webviews/src had 15 distinct blur()
// values; the references use one per role. The stage is the art and a transcript, and one surface of each
// role over it: a scrim band, a bar, a chip, a popover and a menu. "before" draws each at the radius it
// had; the others draw the design scale's three (--ds-blur-scrim 8, --ds-blur-bar 20, --ds-blur-menu 32).
import { type CSSProperties, useEffect } from "react";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../../gallery/format";

type Scheme = "dark" | "light";
type Look = "before" | "three";
type Props = { look: Look; scheme: Scheme };
type Role = "scrim" | "bar" | "chip" | "popover" | "menu";

const SCHEMES: Record<Scheme, Record<string, string>> = {
  dark: {
    "--cmux-surface-background": "transparent",
    "--cmux-surface-solid": "rgb(30, 31, 36)",
    "--cmux-text": "rgb(236, 236, 240)",
    "--cmux-text-secondary": "rgba(236, 236, 240, 0.72)",
  },
  light: {
    "--cmux-surface-background": "transparent",
    "--cmux-surface-solid": "rgb(250, 250, 252)",
    "--cmux-text": "rgb(28, 28, 32)",
    "--cmux-text-secondary": "rgba(28, 28, 32, 0.7)",
  },
};

/** The radius each role blurred at before the scale: the solo tab band 6, a scroll edge 5, the chip
 * 24, the popover 24, the menu 32. */
const BEFORE: Record<Role, string> = {
  scrim: "blur(6px)",
  bar: "blur(20px) saturate(1.4)",
  chip: "blur(24px) saturate(1.6)",
  popover: "blur(24px) saturate(1.25)",
  menu: "blur(32px) saturate(1.6)",
};
const THREE: Record<Role, string> = {
  scrim: "blur(var(--ds-blur-scrim))",
  bar: "var(--ds-glass-chrome-blur)",
  chip: "var(--ds-glass-chip-blur)",
  popover: "var(--ds-glass-popover-blur)",
  menu: "var(--ds-glass-menu-blur)",
};
const TINT: Record<Role, string> = {
  scrim: "30%",
  bar: "var(--ds-glass-chrome-tint)",
  chip: "var(--ds-glass-chip-tint)",
  popover: "var(--ds-glass-popover-tint)",
  menu: "var(--ds-glass-menu-tint)",
};
const BOXES: Record<Role, CSSProperties> = {
  scrim: { left: 0, right: 0, top: 0, height: 40, borderRadius: 0 },
  bar: { left: 24, right: 24, bottom: 16, height: 40, borderRadius: 10 },
  chip: { left: 24, top: 64, width: 150, height: 30, borderRadius: 15 },
  popover: { left: 200, top: 64, width: 250, height: 170, borderRadius: 14 },
  menu: { left: 474, top: 64, width: 240, height: 200, borderRadius: 8 },
};
const LABEL: Record<Role, string> = {
  scrim: "Scrim band",
  bar: "Bar (chrome)",
  chip: "Chip",
  popover: "Popover",
  menu: "Menu",
};

const TRANSCRIPT =
  "Glass works when the content under it is quiet enough to read through and loud enough to feel. Dense rows of text are the hard case, because every letter under the panel competes with every letter on it. ";

function useStage(scheme: Scheme): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("style");
    for (const [name, value] of Object.entries(SCHEMES[scheme])) root.style.setProperty(name, value);
    root.style.colorScheme = scheme;
    root.style.setProperty("background", `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
    root.setAttribute("data-cmux-see-through", "");
    return () => {
      root.removeAttribute("data-cmux-see-through");
      if (saved === null) root.removeAttribute("style");
      else root.setAttribute("style", saved);
    };
  }, [scheme]);
}

function Surface({ role, look }: { role: Role; look: Look }) {
  const backdrop = (look === "before" ? BEFORE : THREE)[role];
  return (
    <div
      data-role={role}
      style={{
        position: "absolute",
        ...BOXES[role],
        boxSizing: "border-box",
        padding: "var(--ds-space-1) var(--ds-space-3)",
        background: `color-mix(in srgb, var(--cmux-surface-solid) ${TINT[role]}, transparent)`,
        backdropFilter: backdrop,
        WebkitBackdropFilter: backdrop,
        boxShadow: role === "scrim" ? undefined : "var(--elevation-2), inset 0 0 0 0.5px var(--ds-glass-edge)",
        maskImage: role === "scrim" ? "linear-gradient(#000 35%, transparent)" : undefined,
        color: "var(--cmux-text)",
        fontSize: "var(--text-body)",
      }}
    >
      <div>{LABEL[role]}</div>
      <div style={{ color: "var(--cmux-text-secondary)", fontSize: "var(--text-detail)" }}>{backdrop}</div>
    </div>
  );
}

function GlassBlurScaleGallery({ look, scheme }: Props) {
  useStage(scheme);
  return (
    <div style={{ position: "relative", height: 330, color: "var(--cmux-text)", fontSize: "var(--text-body)" }}>
      <div style={{ position: "absolute", left: 24, top: 8, right: 24, lineHeight: 1.6, opacity: 0.9 }}>
        {TRANSCRIPT.repeat(5)}
      </div>
      {(["scrim", "bar", "chip", "popover", "menu"] as const).map((role) => (
        <Surface key={role} role={role} look={look} />
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.glass-blur-scale",
  title: "Glass blur radii: scrim, bar, menu",
  area: "Pages",
  height: 350,
  covers: ["pages/shared/desktop.css", "ui/glass/glass.css"],
  load: async () => GlassBlurScaleGallery,
  variants: {
    before: {
      note: "Before: each role at the radius it had (scrim band 6, bar 20, chip 24, popover 24, menu 32), five of the 15 distinct blur() values webviews/src used.",
      props: { look: "before", scheme: "dark" },
    },
    three: {
      note: "Three radii: scrim 8, bar and chip 20, popover and menu 32 (the design scale's --ds-blur-*).",
      props: { look: "three", scheme: "dark" },
    },
    "three-light": {
      note: "Three radii, light theme.",
      props: { look: "three", scheme: "light" },
    },
    "before-light": {
      note: "Before, light theme.",
      props: { look: "before", scheme: "light" },
    },
  },
});
