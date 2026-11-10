// l10n-allow-file: gallery fixtures, not shipped UI.
// Host glass (hostGlass.ts; Leo, 2026-11-06: "why the f*** is this not glass? Like the way the native
// menus are"): a floating surface in a see-through Chromium page, before (the page's own glass, which
// lays the theme surface under its tint because its blur never reaches the window glass) and with the
// App's glass under it. The gallery runs no AppKit, so a stand-in draws the App's part: the wallpaper
// frosted under the surface's box at the popover level's tint, as Glass.makeSurface draws it before
// macOS 26 (Liquid Glass adds its own lit rim on 26). Each variant is a look of the page's part over
// that glass; "clear" ships. The real material is in the Mac captures on the PR.
// The `open-*` variants are the open and close as frames, left to right (Leo, 2026-11-09: "it loads
// the placeholder, THEN the content... every single time"): which of the App's glass and the page's
// content each frame shows, for each way of ordering them.
import { type CSSProperties, useEffect } from "react";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../../gallery/format";

type Scheme = "dark" | "light";
type Look = "before" | "clear" | "rim" | "veil";
/** One frame of an open or close: the App's glass under the box, and the page's part over it (its
 * content on no fill, its content on the page's own glass, or nothing). */
type Frame = { label: string; app: boolean; page: "content" | "page-glass" | "none"; opacity?: number };
/** How a surface opens and closes: the base (content waits for the App's answer), the page's glass
 * first, content and glass sent together (which the App shows as glass first), or the content first
 * and its glass a hold later (ships); and the three ways one closes. */
type Order =
  | "wait"
  | "page-first"
  | "together"
  | "content-first"
  | "close-trailing"
  | "close-page-glass"
  | "close-instant";
/** The surface: Session Info's panel, or the model menu with its own page veil (% of the theme
 * surface); or an open and close as frames. */
type Props = { look: Look; scheme: Scheme; menuVeil?: number; order?: Order };

const ORDERS: Record<Order, Frame[]> = {
  wait: [
    { label: "Mount", app: true, page: "none" },
    { label: "Page busy (260 ms)", app: true, page: "none" },
    { label: "Answer lands", app: true, page: "content" },
    { label: "Close", app: true, page: "none" },
  ],
  "page-first": [
    { label: "Mount", app: false, page: "page-glass" },
    { label: "Page busy (260 ms)", app: true, page: "page-glass" },
    { label: "Answer lands", app: true, page: "content" },
    { label: "Close", app: false, page: "none" },
  ],
  // On screen in the App: its glass commits at once, the page's frame presents two frames later.
  together: [
    { label: "Report (frame 0)", app: true, page: "none" },
    { label: "Frame 1", app: true, page: "none" },
    { label: "Content presents", app: true, page: "content" },
    { label: "Close", app: false, page: "none" },
  ],
  "content-first": [
    { label: "Content presents", app: false, page: "content" },
    { label: "Hold (2 frames)", app: false, page: "content" },
    { label: "Report: glass under", app: true, page: "content" },
    { label: "Close", app: false, page: "none" },
  ],
  // The close (Leo, 2026-11-09, of the This Mac/Cloud/Remote and Bypass permissions menus: "What the heck is
  // this?"): the menu fades for 80 ms, and an empty glass box stayed where it was.
  "close-trailing": [
    { label: "Open", app: true, page: "content" },
    { label: "Fade (40 ms)", app: true, page: "content", opacity: 0.5 },
    { label: "Fade ends", app: true, page: "content", opacity: 0.05 },
    { label: "App still busy", app: true, page: "none" },
  ],
  "close-page-glass": [
    { label: "Open", app: true, page: "content" },
    { label: "Close starts", app: false, page: "page-glass", opacity: 0.85 },
    { label: "Fade (40 ms)", app: false, page: "page-glass", opacity: 0.5 },
    { label: "Gone", app: false, page: "none" },
  ],
  "close-instant": [
    { label: "Open", app: true, page: "content" },
    { label: "Close", app: false, page: "none" },
    { label: "(no fade)", app: false, page: "none" },
    { label: "Gone", app: false, page: "none" },
  ],
};
const MINI = { left: 16, top: 34, width: 200, height: 240, radius: 12 };

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

function AppGlass({ box, scheme, at }: { box: typeof BOX; scheme: Scheme; at: { left: number; top: number } }) {
  return (
    <div
      aria-hidden="true"
      data-testid="app-glass"
      style={{
        position: "absolute",
        left: box.left,
        top: box.top,
        width: box.width,
        height: box.height,
        borderRadius: box.radius,
        overflow: "hidden",
        boxShadow: "var(--elevation-2)",
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: -40,
          background: `url("${wallpaper}") ${-at.left + 40}px ${-at.top + 40}px / 100vw 100vh no-repeat`,
          /* glass-raw-blur-allow: the gallery's stand-in for the App's native glass, not a page glass */
          filter: "blur(30px) saturate(1.6)",
        }}
      />
      <div style={{ position: "absolute", inset: 0, background: APP_TINT[scheme] }} />
    </div>
  );
}

function Rows({ rows }: { rows: string[][] }) {
  return (
    <>
      {rows.map(([title, detail]) => (
        <div key={title} style={{ display: "grid", padding: "var(--ds-space-2) var(--ds-space-4)" }}>
          <span style={{ fontWeight: "var(--weight-emphasis)" }}>{title}</span>
          <span style={{ color: "var(--cmux-text-secondary)" }}>{detail}</span>
        </div>
      ))}
    </>
  );
}

/** An open and close as four frames side by side, each a small stage with the chat beside its box. */
function OpenFrames({ order, scheme }: { order: Order; scheme: Scheme }) {
  useStage(scheme, true);
  return (
    <div style={{ display: "flex", gap: 12, padding: 12, color: "var(--cmux-text)", fontSize: "var(--text-body)" }}>
      {ORDERS[order].map((frame, index) => (
        <div key={frame.label} data-frame={index} style={{ position: "relative", width: 232, height: 290 }}>
          <div style={{ fontWeight: "var(--weight-emphasis)" }}>{frame.label}</div>
          <div style={{ position: "absolute", left: 8, top: 40, width: 216, lineHeight: 1.5, opacity: 0.8 }}>
            {TRANSCRIPT.slice(0, 220)}
          </div>
          {frame.app ? (
            <AppGlass box={MINI} scheme={scheme} at={{ left: 12 + index * 244 + MINI.left, top: 12 + MINI.top }} />
          ) : null}
          {frame.page === "none" ? null : (
            <aside
              className="ui-glass ui-glass-floats"
              data-host-glass={frame.page === "content" ? "popover" : undefined}
              data-host-glass-drawn={frame.page === "content" ? "1" : undefined}
              style={{
                position: "absolute",
                left: MINI.left,
                top: MINI.top,
                width: MINI.width,
                height: MINI.height,
                borderRadius: MINI.radius,
                padding: "var(--ds-space-2) 0",
                display: "grid",
                alignContent: "start",
                ...(frame.opacity !== undefined ? { opacity: frame.opacity } : {}),
              }}
            >
              <Rows rows={ROWS.slice(0, 4)} />
            </aside>
          )}
        </div>
      ))}
    </div>
  );
}

function HostGlassGallery({ look, scheme, menuVeil, order }: Props) {
  return order ? (
    <OpenFrames order={order} scheme={scheme} />
  ) : (
    <HostGlassPanel look={look} scheme={scheme} menuVeil={menuVeil} />
  );
}

function HostGlassPanel({ look, scheme, menuVeil }: Props) {
  const host = look !== "before";
  useStage(scheme, host);
  return (
    <div style={{ position: "relative", height: 440, color: "var(--cmux-text)", fontSize: "var(--text-body)" }}>
      {/* The transcript stops short of the panel, as chatCut.ts leaves its box out. */}
      <div style={{ position: "absolute", left: 24, top: 40, width: 310, lineHeight: 1.5 }}>{TRANSCRIPT.repeat(3)}</div>
      {host ? <AppGlass box={BOX} scheme={scheme} at={BOX} /> : null}
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
        <Rows rows={ROWS} />
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
    "open-wait": {
      note: "Before (Leo, 2026-11-09: 'it loads the placeholder, THEN the content... every single time'): the content waits for the App's answer, which waits behind the page's work after a popup mounts, so the App's glass shows empty for 260 to 530 ms; on close the glass stays a frame past the content.",
      props: { look: "clear", scheme: "dark", order: "wait" },
    },
    "open-page-first": {
      note: "The content on the page's own glass at once, the App's glass taking over when its answer lands: content in the first frame, but the material changes under it a beat later (a flat box, then glass).",
      props: { look: "clear", scheme: "dark", order: "page-first" },
    },
    "open-together": {
      note: "Before (Leo, 2026-11-09, on the empty glass box before the This Mac, Cloud and permission menus): the report goes out in the frame that first paints the content, but the App's glass shows at its next commit and the page's frame presents through Chromium's remote layer two frames later, so the glass shows empty first.",
      props: { look: "clear", scheme: "dark", order: "together" },
    },
    "open-content-first": {
      note: "Ships: the content shows first on the page's in-place blur, and its box goes to the App once that content has been on screen for two frames, so the App's glass lands under content already there. The answer only confirms; the deadline starts at the report.",
      props: { look: "clear", scheme: "dark", order: "content-first" },
    },
    "close-trailing": {
      note: "Before (Leo, 2026-11-09: 'What the heck is this?'): the menu's rows fade for 80 ms in the page while the App's glass, drawn in another process from the page's reports, trails them (a pick keeps the App busy as the menu closes), and the blur under the glass stays whole until the fade ends: an empty glass box where the menu was.",
      props: { look: "clear", scheme: "dark", order: "close-trailing" },
    },
    "close-page-glass": {
      note: "Ships: as the close starts, the App's glass and the blur leave in that task and the rows fade out on the page's own glass, drawn in the same layer, so glass and rows go in the same frames. The cost: the glass is the page's flatter one for the 80 ms fade.",
      props: { look: "clear", scheme: "dark", order: "close-page-glass" },
    },
    "close-instant": {
      note: "Variant: no close fade for a glass menu; rows, glass and blur go in one frame. Never an empty box, but it drops the close animation Leo asked for on 2026-10-24.",
      props: { look: "clear", scheme: "dark", order: "close-instant" },
    },
    "open-content-first-light": {
      note: "Ships, light theme.",
      props: { look: "clear", scheme: "light", order: "content-first" },
    },
    veil: {
      note: "The App's glass plus a 20% theme veil from the page: the wallpaper is calmer under the text, and the glass is denser than every native popover's.",
      props: { look: "veil", scheme: "dark" },
    },
  },
});
