// l10n-allow-file: gallery fixtures, not shipped UI.
// Host glass (hostGlass.ts; Leo, 2026-11-06: "why the f*** is this not glass? Like the way the native
// menus are"): a floating surface in a see-through Chromium page, before (the page's own glass, which
// lays the theme surface under its tint because its blur never reaches the window glass) and with the
// App's glass under it. The gallery runs no AppKit, so a stand-in draws the App's part: the wallpaper
// frosted under the surface's box at the popover level's tint, as Glass.makeSurface draws it before
// macOS 26 (Liquid Glass adds its own lit rim on 26). Each variant is a look of the page's part over
// that glass; "clear" ships. The real material is in the Mac captures on the PR.
import { type CSSProperties, useEffect } from "react";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../../gallery/format";

type Scheme = "dark" | "light";
type Look = "before" | "clear" | "rim" | "veil";
/** The surface: Session Info's panel, or the model menu with its own page veil (% of the theme surface). */
type Props = { look: Look; scheme: Scheme; menuVeil?: number };

const SCHEMES: Record<Scheme, Record<string, string>> = {
  dark: {
    "--cmux-surface-background": "transparent",
    "--cmux-surface-solid": "rgb(30, 31, 36)",
    "--cmux-text": "rgb(236, 236, 240)",
    "--cmux-text-secondary": "rgba(236, 236, 240, 0.72)",
    "--cmux-card-rim": "rgba(255, 255, 255, 0.14)",
  },
  light: {
    "--cmux-surface-background": "transparent",
    "--cmux-surface-solid": "rgb(250, 250, 252)",
    "--cmux-text": "rgb(28, 28, 32)",
    "--cmux-text-secondary": "rgba(28, 28, 32, 0.7)",
    "--cmux-card-rim": "rgba(0, 0, 0, 0.1)",
  },
};
/** The App's popover glass, as the stand-in draws it: the theme's glass tint at the popover level (×1.25). */
const APP_TINT: Record<Scheme, string> = { dark: "rgba(30, 31, 36, 0.5)", light: "rgba(250, 250, 252, 0.38)" };
/** The page's part over the App's glass, per look (glass.css --host-glass-fill and --host-glass-edge). */
const LOOKS: Record<Exclude<Look, "before">, CSSProperties> = {
  clear: {},
  rim: { "--host-glass-edge": "var(--glass-rim-shadow)" } as CSSProperties,
  veil: { "--host-glass-fill": "color-mix(in srgb, var(--cmux-surface-solid) 20%, transparent)" } as CSSProperties,
};
const BOX = { left: 360, top: 40, width: 300, height: 360, radius: 12 };

function useStage(scheme: Scheme, host: boolean): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("style");
    for (const [name, value] of Object.entries(SCHEMES[scheme])) root.style.setProperty(name, value);
    root.style.colorScheme = scheme;
    // The window glass behind the see-through page: in the app it is native, under the page.
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

const ROWS = [
  ["Environment", "This Mac · cmux-next"],
  ["Context", "41% of 200k"],
  ["Pull request", "#37601 open"],
  ["Subagents", "2 running"],
  ["Background tasks", "bun test (12 s)"],
  ["Outputs", "3 files"],
];

const TRANSCRIPT =
  "I traced the stutter to the transcript's scroll handler: every wheel event read the composer's height, which forced a layout right after the virtualizer moved its rows. The fix reads the height once per frame from the resize observer that already watches the composer. ";

function HostGlassGallery({ look, scheme, menuVeil }: Props) {
  const host = look !== "before";
  useStage(scheme, host);
  return (
    <div style={{ position: "relative", height: 440, color: "var(--cmux-text)", fontSize: "var(--text-body)" }}>
      {/* The transcript stops short of the panel, as chatCut.ts leaves its box out. */}
      <div style={{ position: "absolute", left: 24, top: 40, width: 310, lineHeight: 1.5 }}>{TRANSCRIPT.repeat(3)}</div>
      {host ? (
        <div
          aria-hidden="true"
          data-testid="app-glass"
          style={{
            position: "absolute",
            left: BOX.left,
            top: BOX.top,
            width: BOX.width,
            height: BOX.height,
            borderRadius: BOX.radius,
            overflow: "hidden",
            boxShadow: "var(--elevation-2)",
          }}
        >
          <div
            style={{
              position: "absolute",
              inset: -40,
              background: `url("${wallpaper}") ${-BOX.left + 40}px ${-BOX.top + 40}px / 100vw 100vh no-repeat`,
              /* glass-raw-blur-allow: the gallery's stand-in for the App's native glass, not a page glass */
              filter: "blur(30px) saturate(1.6)",
            }}
          />
          <div style={{ position: "absolute", inset: 0, background: APP_TINT[scheme] }} />
        </div>
      ) : null}
      <aside
        className="ui-glass ui-glass-floats"
        data-host-glass={host ? "popover" : undefined}
        data-host-glass-drawn={host ? "1" : undefined}
        style={{
          position: "absolute",
          left: BOX.left,
          top: BOX.top,
          width: BOX.width,
          height: BOX.height,
          borderRadius: BOX.radius,
          padding: "var(--ds-space-2) 0",
          display: "grid",
          alignContent: "start",
          ...(host ? LOOKS[look] : {}),
          ...(host && menuVeil !== undefined
            ? ({
                "--host-glass-fill": `color-mix(in srgb, var(--cmux-surface-solid) ${menuVeil}%, transparent)`,
              } as CSSProperties)
            : {}),
        }}
      >
        {ROWS.map(([title, detail]) => (
          <div key={title} style={{ display: "grid", padding: "var(--ds-space-2) var(--ds-space-4)" }}>
            <span style={{ fontWeight: "var(--weight-emphasis)" }}>{title}</span>
            <span style={{ color: "var(--cmux-text-secondary)" }}>{detail}</span>
          </div>
        ))}
      </aside>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.host-glass",
  title: "Host glass",
  area: "Pages",
  height: 460,
  covers: ["ui/glass/hostGlass.ts#reportHostGlass"],
  load: async () => HostGlassGallery,
  variants: {
    before: {
      note: "Before: the page's own glass in a see-through Chromium page. Its blur never reaches the window glass, so it lays the theme surface under its tint and reads as a flat box (Leo: 'why the f*** is this not glass?').",
      props: { look: "before", scheme: "dark" },
    },
    clear: {
      note: "Ships: the App's popover glass under the page, and the page draws only the content, as a native popover draws its views on its glass. No tint, rim or shadow of the page's own.",
      props: { look: "clear", scheme: "dark" },
    },
    "clear-light": {
      note: "Ships, light theme.",
      props: { look: "clear", scheme: "light" },
    },
    rim: {
      note: "The App's glass plus the page's specular rim. On macOS 26 Liquid Glass lights its own edge, so this draws two edges.",
      props: { look: "rim", scheme: "dark" },
    },
    "model-0": {
      note: "The model menu on the App's glass with no page veil: the wallpaper's color comes into the row text.",
      props: { look: "clear", scheme: "dark", menuVeil: 0 },
    },
    "model-40": {
      note: "Ships for the model menu: a 40% page veil on the App's glass, so its rows never read the chat through them (Leo, 2026-10-31) and it is still glass.",
      props: { look: "clear", scheme: "dark", menuVeil: 40 },
    },
    "model-70": {
      note: "A 70% page veil: reads as the solid card again.",
      props: { look: "clear", scheme: "dark", menuVeil: 70 },
    },
    veil: {
      note: "The App's glass plus a 20% theme veil from the page: the wallpaper is calmer under the text, and the glass is denser than every native popover's.",
      props: { look: "veil", scheme: "dark" },
    },
  },
});
