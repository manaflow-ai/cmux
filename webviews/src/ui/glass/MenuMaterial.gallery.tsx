// l10n-allow-file: gallery fixtures, not shipped UI.
// One floating material (glass.css GLASS LEVELS; design/surface-materials.md "One floating material").
// Leo, 2026-11-11, on the context card over the composer beside the model picker and the native menus:
// "Like, man, it's really f***ing ugly when it mixes like this, you know?" and "The whole point is to
// have things show through to show off the f***ing art. The point is, the styles mix and they don't
// look good. So they need to look good." His reference is the account menu of a desktop chat app: one translucent
// surface, one radius, one row rhythm, the art behind it calm but present.
//
// The stage is the art, a transcript over it, and three surfaces open side by side as they were in his
// captures: a menu (the chat's right-click rows), the context ring's card and the model menu. Each
// variant is one way to draw all three. The App's glass under the page (host glass) is a stand-in:
// the art frosted under the box at the menu level's tint, as Glass.makeSurface draws it before macOS 26
// (HostGlass.gallery.tsx does the same). The real material is in the Mac captures on the PR.
import { type CSSProperties, type ReactNode, useEffect } from "react";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { CheckIcon } from "../../agent-session/acpmux/ComposerPickers";
import { componentEntry } from "../../gallery/format";

type Scheme = "dark" | "light";
/** before: each surface's own look as shipped until 2026-11-11. one: every surface the menu level on
 * the page's glass. host-clear / host-veil: the App's glass under every surface, with no page veil or
 * the one 40% veil (ships). dense: every surface at the old + menu's 86%. */
type Look = "before" | "one" | "host-clear" | "host-veil" | "dense";
type Props = { look: Look; scheme: Scheme };
type Surface = "menu" | "card" | "model";

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
/** The App's menu glass as the stand-in draws it: the theme's glass tint at the menu level (x1.25). */
const APP_TINT: Record<Scheme, string> = { dark: "rgba(30, 31, 36, 0.5)", light: "rgba(250, 250, 252, 0.38)" };

const tint = (share: string) => `color-mix(in srgb, var(--glass-surface) ${share}, transparent)`;
/** Each surface's own glass before: the context card on the popover level, the model menu at 92% with
 * a 10 px radius, the menus on the menu level. */
const BEFORE: Record<Surface, CSSProperties> = {
  menu: {},
  card: {
    "--glass-tint": tint("var(--ds-glass-popover-tint)"),
    "--glass-backdrop": "var(--ds-glass-popover-blur)",
  } as CSSProperties,
  model: { "--glass-tint": tint("92%"), borderRadius: 10 } as CSSProperties,
};
const LOOK: Record<Exclude<Look, "before">, CSSProperties> = {
  one: {},
  "host-clear": { "--host-glass-fill": "transparent" } as CSSProperties,
  "host-veil": {},
  dense: { "--glass-tint": tint("86%") } as CSSProperties,
};
const hosted = (look: Look) => look === "host-clear" || look === "host-veil";

const BOXES: Record<Surface, { left: number; top: number; width: number; height: number }> = {
  menu: { left: 24, top: 36, width: 232, height: 252 },
  card: { left: 280, top: 150, width: 230, height: 138 },
  model: { left: 534, top: 60, width: 236, height: 228 },
};

const TRANSCRIPT =
  "Then I just feel like there's some parts of this where it just feels so weird to look at. Should this really be native? What do we even want to have native versus non-native? If I right-click in the chat, do we expect these to be in React instead? ";

function useStage(scheme: Scheme, host: boolean): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("style");
    for (const [name, value] of Object.entries(SCHEMES[scheme])) root.style.setProperty(name, value);
    root.style.colorScheme = scheme;
    // The window's art behind the see-through page: in the app it is native, under the page.
    root.style.setProperty("background", `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
    root.setAttribute("data-cmux-see-through", "");
    root.toggleAttribute("data-host-glass-on", host);
    return () => {
      root.removeAttribute("data-cmux-see-through");
      root.removeAttribute("data-host-glass-on");
      if (saved === null) root.removeAttribute("style");
      else root.setAttribute("style", saved);
    };
  }, [scheme, host]);
}

function AppGlass({ surface, scheme }: { surface: Surface; scheme: Scheme }) {
  const box = BOXES[surface];
  return (
    <div
      aria-hidden="true"
      data-testid="app-glass"
      style={{
        position: "absolute",
        ...box,
        borderRadius: "var(--ui-popup-radius)",
        overflow: "hidden",
        boxShadow: "var(--elevation-2)",
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: -40,
          background: `url("${wallpaper}") ${-box.left + 28}px ${-box.top + 28}px / 100vw 100vh no-repeat`,
          /* glass-raw-blur-allow: the gallery's stand-in for the App's native glass, not a page glass */
          filter: "blur(32px) saturate(1.6)",
        }}
      />
      <div style={{ position: "absolute", inset: 0, background: APP_TINT[scheme] }} />
    </div>
  );
}

const MENU_ROWS = [
  "Send Message…",
  "Fork Conversation",
  "Change Background…",
  "Move to Cloud",
  "Find in Chat…",
  "Copy Agent Identifier",
  "Point at Element…",
];
const MODEL_ROWS = ["Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 5.5", "Effort", "Fast mode"];

function Rows({ rows, chosen }: { rows: string[]; chosen?: string }) {
  return (
    <>
      {rows.map((row) => (
        <div
          key={row}
          role="menuitem"
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            height: "var(--ui-row-height)",
            padding: "0 var(--ds-space-2)",
          }}
        >
          <span>{row}</span>
          {row === chosen ? <CheckIcon /> : null}
        </div>
      ))}
    </>
  );
}

function Floating({ surface, look, children }: { surface: Surface; look: Look; children: ReactNode }) {
  const own = look === "before" ? BEFORE[surface] : LOOK[look];
  const host = hosted(look);
  return (
    <div
      className={surface === "card" ? "ui-card ui-glass" : "ui-popup ui-glass ui-menu"}
      data-surface={surface}
      data-host-glass={host ? "menu" : undefined}
      data-host-glass-drawn={host ? "1" : undefined}
      style={{
        position: "absolute",
        ...BOXES[surface],
        boxSizing: "border-box",
        padding: "var(--ui-popup-padding)",
        borderRadius: "var(--ui-popup-radius)",
        color: "var(--cmux-text)",
        fontSize: "var(--text-body)",
        ...own,
      }}
    >
      {children}
    </div>
  );
}

function MenuMaterialGallery({ look, scheme }: Props) {
  const host = hosted(look);
  useStage(scheme, host);
  return (
    <div style={{ position: "relative", height: 320, color: "var(--cmux-text)", fontSize: "var(--text-body)" }}>
      <div style={{ position: "absolute", left: 24, top: 24, right: 24, lineHeight: 1.6, opacity: 0.9 }}>
        {TRANSCRIPT.repeat(4)}
      </div>
      {host
        ? (["menu", "card", "model"] as const).map((surface) => (
            <AppGlass key={surface} surface={surface} scheme={scheme} />
          ))
        : null}
      <Floating surface="menu" look={look}>
        <Rows rows={MENU_ROWS} />
      </Floating>
      <Floating surface="card" look={look}>
        <div style={{ display: "grid", gap: "var(--ds-space-1)", padding: "var(--ds-space-2)" }}>
          <span style={{ color: "var(--cmux-text-secondary)" }}>Context window</span>
          <span style={{ fontWeight: "var(--weight-emphasis)" }}>91% used · 365K / 399.1K</span>
          <span>Messages · 320.1K</span>
          <span>Agent setup · 36.5K</span>
        </div>
      </Floating>
      <Floating surface="model" look={look}>
        <Rows rows={MODEL_ROWS} chosen="Opus 5.5" />
      </Floating>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.menu-material",
  title: "One floating material",
  area: "Pages",
  height: 340,
  covers: ["ui/Tooltip.tsx#AnchoredCard", "ui/glass/hostGlass.ts#reportHostGlass"],
  load: async () => MenuMaterialGallery,
  variants: {
    before: {
      note: "Before (Leo, 2026-11-11: 'it's really f***ing ugly when it mixes like this'): the menu on the menu level (78%, 32 px), the context card on the popover level (70%, 24 px) and the model menu at 92% with a 10 px corner; on the App's glass only the model menu laid a veil. Three materials side by side.",
      props: { look: "before", scheme: "dark" },
    },
    one: {
      note: "One material on the page's glass (WebKit pages, an App without host glass): every surface the menu level, one radius.",
      props: { look: "one", scheme: "dark" },
    },
    "host-clear": {
      note: "One material on the App's glass with no page veil: the most art, but the wallpaper's color comes into the row text (the reason the model menu had its veil).",
      props: { look: "host-clear", scheme: "dark" },
    },
    "host-veil": {
      note: "Ships: the App's glass under every popup and card with one 40% veil of the theme surface, the model menu's since cmux#37794. The art shows through every surface the same way.",
      props: { look: "host-veil", scheme: "dark" },
    },
    "host-veil-light": {
      note: "Ships, light theme.",
      props: { look: "host-veil", scheme: "light" },
    },
    dense: {
      note: "Every surface at the old + menu's 86%: one material too, but the art mostly goes (Leo: 'The whole point is to have things show through to show off the f***ing art').",
      props: { look: "dense", scheme: "dark" },
    },
  },
});
