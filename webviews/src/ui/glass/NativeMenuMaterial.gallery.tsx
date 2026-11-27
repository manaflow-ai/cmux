// l10n-allow-file: gallery fixtures, not shipped UI.
// The account menu on cmux's own glass (GlassMenu, GlassMenuMaterial.swift; design/surface-materials.md
// "One floating material"). Leo, 2026-11-11, of drawing the sidebar's account menu in Swift on our own
// glass instead of AppKit's menu: "Well, that's the whole point, right? Like that's what we wanted to do
// anyways. have better design (systems too)". His reference is the account menu of a desktop chat app:
// one translucent surface, one radius, one row rhythm, the art behind it calm but present.
//
// A stand-in, drawn on the web side from the same numbers (design-scale.json's menu level: tint 78%,
// veil 40%, blur 32 px, popup radius 8, row 28; the AppKit menu grid: highlight inset 5, icon at 15,
// text at 35, shortcut 12 from the edge). The stage is the art at the window's bottom-left, the sidebar
// over it and the account menu open above the avatar, with a web menu beside it so the two can be
// compared side by side. The real material is in the Mac captures on the PR.
import { type CSSProperties, useEffect } from "react";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../../gallery/format";

type Scheme = "dark" | "light";
/** system: AppKit's NSMenu as it shipped until 2026-11-11 (its own material, 6 px corner, 22 px rows,
 * its own highlight), next to the web menu on the shared glass. clear: GlassMenu with no veil.
 * veil: GlassMenu with the one 40% veil (ships). dense: GlassMenu at the old + menu's 86%. */
type Look = "system" | "clear" | "veil" | "dense";
type Props = { look: Look; scheme: Scheme; submenu?: boolean };

const INK: Record<
  Scheme,
  { text: string; secondary: string; tertiary: string; surface: string; glass: string; highlight: string }
> = {
  dark: {
    text: "rgb(236, 236, 240)",
    secondary: "rgba(236, 236, 240, 0.72)",
    tertiary: "rgba(236, 236, 240, 0.5)",
    surface: "rgb(30, 31, 36)",
    glass: "rgba(30, 31, 36, 0.5)",
    highlight: "rgba(255, 255, 255, 0.1)",
  },
  light: {
    text: "rgb(28, 28, 32)",
    secondary: "rgba(28, 28, 32, 0.7)",
    tertiary: "rgba(28, 28, 32, 0.45)",
    surface: "rgb(250, 250, 252)",
    glass: "rgba(250, 250, 252, 0.38)",
    highlight: "rgba(0, 0, 0, 0.07)",
  },
};
/** AppKit's menu material as the stand-in draws it: brighter, more saturated, nearly solid. */
const SYSTEM: Record<Scheme, string> = { dark: "rgba(44, 44, 48, 0.86)", light: "rgba(236, 236, 238, 0.86)" };
/** AppKit's selected-row blue in that stand-in. */
const SYSTEM_SELECTION = "rgb(10, 100, 220)";
/** The sidebar avatar the account menu opens from. */
const AVATAR = { left: 16, bottom: 16, background: "rgb(120, 90, 200)" };
/** The caption over the web menu, beside the native one. */
const WEB_CAPTION = { left: 560, top: 70 };
const VEIL: Record<Exclude<Look, "system">, number> = { clear: 0, veil: 40, dense: 86 };

type Row = { title: string; subtitle?: string; icon?: string; shortcut?: string; chevron?: boolean; check?: boolean };
type Line = Row | "separator";
const ACCOUNT: Line[] = [
  { title: "Leo", subtitle: "leo@example.com", icon: "L" },
  "separator",
  { title: "Personal", subtitle: "Your own team", icon: "👤", check: true },
  { title: "Team", subtitle: "4 members", icon: "👥" },
  "separator",
  { title: "Profile", icon: "◐", chevron: true },
  { title: "Help", icon: "?", chevron: true },
  { title: "Hide Chief", icon: "✦" },
  { title: "Personalization…", icon: "◑" },
  { title: "Settings…", icon: "⚙", shortcut: "⌘," },
  { title: "Check for Updates…", icon: "↻" },
  "separator",
  { title: "Sign Out", icon: "⎋" },
];
const HELP: Line[] = [
  { title: "Keyboard Shortcuts", shortcut: "⌘/" },
  { title: "What's New" },
  { title: "Send Feedback…" },
];

const GRID = { inset: 5, iconX: 15, icon: 14, textX: 35, trailing: 12, row: 28, radius: 8 };

function useStage(scheme: Scheme): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("style");
    root.style.colorScheme = scheme;
    root.style.setProperty("background", `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
    return () => {
      if (saved === null) root.removeAttribute("style");
      else root.setAttribute("style", saved);
    };
  }, [scheme]);
}

function Glass({
  box,
  look,
  scheme,
}: {
  box: CSSProperties & { left: number; top: number };
  look: Look;
  scheme: Scheme;
}) {
  const ink = INK[scheme];
  const system = look === "system";
  return (
    <div
      aria-hidden="true"
      style={{
        position: "absolute",
        ...box,
        borderRadius: system ? 6 : GRID.radius,
        overflow: "hidden",
        boxShadow: "var(--elevation-2)",
        outline: `0.5px solid ${scheme === "dark" ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)"}`,
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: -40,
          background: `url("${wallpaper}") ${-box.left + 40}px ${-box.top + 40}px / 100vw 100vh no-repeat`,
          /* glass-raw-blur-allow: the gallery's stand-in for the App's native glass, not a page glass */
          filter: system ? "blur(40px) saturate(2)" : "blur(32px) saturate(1.6)",
        }}
      />
      <div style={{ position: "absolute", inset: 0, background: system ? SYSTEM[scheme] : ink.glass }} />
      {system ? null : (
        <div
          style={{
            position: "absolute",
            inset: 0,
            background: `color-mix(in srgb, ${ink.surface} ${VEIL[look]}%, transparent)`,
          }}
        />
      )}
    </div>
  );
}

function Menu({
  lines,
  left,
  top,
  width,
  look,
  scheme,
  highlighted,
}: {
  lines: Line[];
  left: number;
  top: number;
  width: number;
  look: Look;
  scheme: Scheme;
  highlighted?: string;
}) {
  const ink = INK[scheme];
  const system = look === "system";
  const row = system ? 22 : GRID.row;
  const height =
    GRID.inset * 2 +
    lines.reduce((sum, line) => sum + (line === "separator" ? 9 : line.subtitle && !system ? 40 : row), 0);
  const icons = lines.some((line) => line !== "separator" && line.icon);
  const textX = icons ? GRID.textX : GRID.iconX;
  return (
    <>
      <Glass box={{ left, top, width, height }} look={look} scheme={scheme} />
      <div
        role="menu"
        style={{ position: "absolute", left, top, width, height, padding: GRID.inset, boxSizing: "border-box" }}
      >
        {lines.map((line, index) =>
          line === "separator" ? (
            <div
              key={`separator-${index}`}
              style={{
                height: 9,
                display: "flex",
                alignItems: "center",
                padding: `0 ${GRID.iconX - GRID.inset}px`,
              }}
            >
              <div style={{ height: 1, flex: 1, background: "var(--cmux-separator, rgba(127,127,127,0.25))" }} />
            </div>
          ) : (
            <div
              key={line.title}
              role="menuitem"
              style={{
                position: "relative",
                height: line.subtitle && !system ? 40 : row,
                borderRadius: system ? 4 : "var(--cmux-menu-highlight-radius)",
                background: line.title === highlighted ? (system ? SYSTEM_SELECTION : ink.highlight) : undefined,
                color: line.title === highlighted && system ? "white" : ink.text,
                fontSize: system ? 13 : "var(--text-body)",
              }}
            >
              {line.icon ? (
                <span
                  style={{
                    position: "absolute",
                    left: GRID.iconX - GRID.inset,
                    top: "50%",
                    width: GRID.icon,
                    transform: "translateY(-50%)",
                    textAlign: "center",
                    fontSize: "var(--text-caption)",
                  }}
                >
                  {line.icon}
                </span>
              ) : null}
              <span
                style={{
                  position: "absolute",
                  left: textX - GRID.inset,
                  top: "50%",
                  transform: "translateY(-50%)",
                  display: "grid",
                  lineHeight: 1.25,
                }}
              >
                <span>{line.title}</span>
                {line.subtitle && !system ? (
                  <span style={{ color: ink.secondary, fontSize: "var(--text-caption)" }}>{line.subtitle}</span>
                ) : null}
              </span>
              <span
                style={{
                  position: "absolute",
                  right: GRID.trailing - GRID.inset,
                  top: "50%",
                  transform: "translateY(-50%)",
                  color: line.check ? ink.text : ink.tertiary,
                }}
              >
                {line.chevron ? "›" : line.check ? "✓" : (line.shortcut ?? "")}
              </span>
            </div>
          ),
        )}
      </div>
    </>
  );
}

function NativeMenuMaterialGallery({ look, scheme, submenu }: Props) {
  useStage(scheme);
  const ink = INK[scheme];
  return (
    <div style={{ position: "relative", height: 520, color: ink.text, fontSize: "var(--text-body)" }}>
      <div
        style={{
          position: "absolute",
          left: 0,
          top: 0,
          bottom: 0,
          width: 240,
          background: `color-mix(in srgb, ${ink.surface} 30%, transparent)`,
        }}
      />
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          ...AVATAR,
          width: 24,
          height: 24,
          borderRadius: 12,
          color: "white",
          display: "grid",
          placeItems: "center",
          fontSize: "var(--text-caption)",
        }}
      >
        L
      </div>
      <Menu
        lines={ACCOUNT}
        left={12}
        top={70}
        width={260}
        look={look}
        scheme={scheme}
        highlighted={submenu ? "Help" : "Settings…"}
      />
      {submenu ? <Menu lines={HELP} left={276} top={260} width={230} look={look} scheme={scheme} /> : null}
      <div style={{ position: "absolute", ...WEB_CAPTION, color: ink.secondary, fontSize: "var(--text-caption)" }}>
        Web menu, same material
      </div>
      <Menu
        lines={[
          { title: "Send Message…" },
          { title: "Fork Conversation" },
          { title: "Find in Chat…", shortcut: "⌘F" },
          "separator",
          { title: "Copy Agent Identifier" },
        ]}
        left={560}
        top={92}
        width={220}
        look={look === "system" ? "veil" : look}
        scheme={scheme}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.native-menu-material",
  title: "Account menu on our glass",
  area: "Pages",
  height: 540,
  covers: ["swift:GlassMenu", "swift:GlassMenuMaterial"],
  load: async () => NativeMenuMaterialGallery,
  variants: {
    system: {
      note: "Before: AppKit's NSMenu (its own material, 6 px corner, 22 px rows, the blue highlight) beside a web menu on the shared glass. Two materials side by side.",
      props: { look: "system", scheme: "dark" },
    },
    clear: {
      note: "GlassMenu with no veil: the most art, but the wallpaper's color comes into the row text.",
      props: { look: "clear", scheme: "dark" },
    },
    veil: {
      note: "Ships: GlassMenu on the menu glass with the one 40% veil, 8 px corner, 28 px rows on the menu grid. The account menu and the web menu are one material.",
      props: { look: "veil", scheme: "dark" },
    },
    "veil-light": {
      note: "Ships, light theme.",
      props: { look: "veil", scheme: "light" },
    },
    "veil-submenu": {
      note: "Ships, with the Help submenu open beside its row (the pointer or Right opens it; Left closes it).",
      props: { look: "veil", scheme: "dark", submenu: true },
    },
    "veil-submenu-light": {
      note: "Ships, light theme, submenu open.",
      props: { look: "veil", scheme: "light", submenu: true },
    },
    dense: {
      note: "GlassMenu at the old + menu's 86%: one material too, but the art mostly goes.",
      props: { look: "dense", scheme: "dark" },
    },
  },
});
