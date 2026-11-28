// l10n-allow-file: gallery fixtures, not shipped UI.
// Liquid glass (plans/cmux-next/glass-lens-DESIGN.md): the shared `.ui-glass` surface and its lens
// over a colorful wallpaper, as the app draws it. The wallpaper is painted as the page background
// (in the app it is native, behind the transparent web view) and the same still goes through
// `cmuxTheme.backdrop` with the viewport as its rect, so the lens takes the path it takes in the app.
// The see-through variant paints nothing behind the page, as a Chromium page over the window glass:
// the glass's backdrop then has no wallpaper in it (glass.css, "CHROMIUM OVER THE WINDOW GLASS").
import { useEffect } from "react";
import { experimentArm } from "../../experiments/experiment";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../../gallery/format";
import { chromiumGlassUnderlay } from "./chromiumUnderlay.experiment";
import { Glass } from "./Glass";
import { installSvgRefraction } from "./svgRefraction";
import type { GlassMode } from "./glassState";

type Scheme = "dark" | "light";
/** The lens's look, as tokens on the root (glass.css): unset keeps the mode's own. */
type Look = { gloss?: number; magnify?: number; refraction?: number };
type Props = {
  mode: GlassMode;
  scheme: Scheme;
  transcript?: boolean;
  seeThrough?: boolean;
  look?: Look;
  /** Chromium's SVG feDisplacementMap backdrop instead of the lens (svgRefraction.ts). */
  svg?: boolean;
};

/** The theme tokens each scheme sets, as WebTheme.swift does, over a see-through window. */
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
/** The native wash over the art (the window tint). */
const TINT: Record<Scheme, string> = { dark: "rgba(0, 0, 0, 0.18)", light: "rgba(255, 255, 255, 0.16)" };

type BackdropHost = { cmuxTheme?: { backdrop?: (partial: unknown) => void } };

function useLook(look: Look | undefined, svg: boolean): void {
  const { gloss, magnify, refraction } = look ?? {};
  useEffect(() => {
    const root = document.documentElement;
    const set: [string, number | undefined, string][] = [
      ["--glass-gloss", gloss, ""],
      ["--glass-magnify", magnify, ""],
      ["--glass-refraction", refraction, "px"],
    ];
    for (const [name, value, unit] of set) if (value !== undefined) root.style.setProperty(name, `${value}${unit}`);
    const undoSvg = svg ? installSvgRefraction(document) : undefined;
    return () => {
      undoSvg?.();
      for (const [name] of set) root.style.removeProperty(name);
    };
  }, [gloss, magnify, refraction, svg]);
}

function useWallpaper(mode: GlassMode, scheme: Scheme, seeThrough: boolean): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("style");
    const savedGlass = root.getAttribute("data-glass");
    const savedTheme = root.getAttribute("data-theme");
    for (const [name, value] of Object.entries(SCHEMES[scheme])) root.style.setProperty(name, value);
    root.style.colorScheme = scheme;
    root.setAttribute("data-theme", scheme);
    root.setAttribute("data-glass", mode);
    if (seeThrough) {
      // No wallpaper and no still: the page is clear, the tint the window's (desktop.ts).
      root.style.setProperty("background", "transparent", "important");
      root.setAttribute("data-cmux-see-through", "");
      root.setAttribute("data-glass-underlay", experimentArm(chromiumGlassUnderlay));
      return () => {
        root.removeAttribute("data-cmux-see-through");
        root.removeAttribute("data-glass-underlay");
        if (saved === null) root.removeAttribute("style");
        else root.setAttribute("style", saved);
        if (savedGlass === null) root.removeAttribute("data-glass");
        else root.setAttribute("data-glass", savedGlass);
        if (savedTheme === null) root.removeAttribute("data-theme");
        else root.setAttribute("data-theme", savedTheme);
      };
    }
    const tint = TINT[scheme];
    root.style.setProperty(
      "background",
      `linear-gradient(${tint}, ${tint}) fixed, url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`,
      "important",
    );
    const send = () =>
      (window as unknown as BackdropHost).cmuxTheme?.backdrop?.({
        image: wallpaper,
        key: "gallery-liquid-glass",
        rect: { x: 0, y: 0, width: root.clientWidth, height: root.clientHeight },
        blur: 0,
        tint,
      });
    send();
    window.addEventListener("resize", send);
    return () => {
      window.removeEventListener("resize", send);
      (window as unknown as BackdropHost).cmuxTheme?.backdrop?.({ image: null, key: null });
      if (saved === null) root.removeAttribute("style");
      else root.setAttribute("style", saved);
      if (savedGlass === null) root.removeAttribute("data-glass");
      else root.setAttribute("data-glass", savedGlass);
      if (savedTheme === null) root.removeAttribute("data-theme");
      else root.setAttribute("data-theme", savedTheme);
    };
  }, [mode, scheme, seeThrough]);
}

const text = { color: "var(--cmux-text)" } as const;
const secondary = { color: "var(--cmux-text-secondary)" } as const;

const PARAGRAPHS = [
  "I traced the stutter to the transcript's scroll handler: every wheel event read the composer's height, which forced a layout right after the virtualizer moved its rows.",
  "The fix reads the height once per frame from the resize observer that already watches the composer, and the handler only marks the frame dirty. Scrolling a 2,000-message session now holds 60 frames per second on the laptop.",
  "I also checked the glass surfaces: the lens reads every rect in one pass, draws only when one moved, and stops after twenty quiet frames, so an idle pane costs nothing.",
  "Two tests cover it: one scrolls a long fixture and counts long frames, the other checks that the composer's height is read at most once per frame.",
  "Next I would like to move the jump-to-latest pill onto the same glass, so it bends the wallpaper like the composer does.",
  "The composer sits over the transcript as it scrolls: the glass frosts the lines under it instead of letting each letter read through the tint.",
];

/** Transcript-like text with the composer and an open menu over it. */
function TranscriptUnderGlass() {
  return (
    <div
      style={{
        position: "relative",
        minHeight: "100vh",
        padding: "24px 32px",
        boxSizing: "border-box",
        fontSize: "var(--text-content)",
        lineHeight: "var(--text-content--line-height)",
        ...text,
      }}
    >
      {PARAGRAPHS.map((paragraph) => (
        <p key={paragraph.slice(0, 24)} style={{ margin: "0 0 14px", maxWidth: 680 }}>
          {paragraph}
        </p>
      ))}
      <Glass
        role="menu"
        className="ui-glass-floats"
        style={{
          position: "absolute",
          top: 70,
          right: 60,
          width: 220,
          padding: 5,
          borderRadius: 12,
          display: "grid",
          fontSize: "var(--text-control)",
          lineHeight: "var(--text-control--line-height)",
        }}
      >
        {["Copy", "Quote in reply", "Fork from here", "Delete"].map((label) => (
          <div key={label} role="menuitem" style={{ padding: "5px 10px", borderRadius: 7 }}>
            {label}
          </div>
        ))}
      </Glass>
      <Glass
        className="ui-glass-floats"
        style={{
          position: "absolute",
          left: 28,
          right: 28,
          // Over the last paragraphs, as the composer sits over the transcript while it scrolls.
          top: 250,
          minHeight: 92,
          padding: "14px 16px",
          borderRadius: 22,
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
        }}
      >
        <span>Move the jump pill onto the glass too</span>
        <div style={{ display: "flex", gap: 8, fontSize: "var(--text-control)", ...secondary }}>
          <span>Plan</span>
          <span>Claude</span>
          <span style={{ marginInlineStart: "auto" }}>⌘↩</span>
        </div>
      </Glass>
    </div>
  );
}

function LiquidGlassGallery({ mode, scheme, transcript = false, seeThrough = false, look, svg = false }: Props) {
  useWallpaper(mode, scheme, seeThrough);
  useLook(look, svg);
  if (transcript) return <TranscriptUnderGlass />;
  return (
    <div
      style={{
        position: "relative",
        minHeight: "100vh",
        padding: 28,
        boxSizing: "border-box",
        fontSize: "var(--text-body)",
        lineHeight: "var(--text-body--line-height)",
        ...text,
      }}
    >
      <div style={{ display: "flex", gap: 28, alignItems: "flex-start", flexWrap: "wrap" }}>
        <div style={{ display: "grid", gap: 14, width: 320 }}>
          <Glass style={{ justifySelf: "end", maxWidth: 260, padding: "10px 14px", borderRadius: 18 }}>
            Can you bend the wallpaper at the edge of this bubble?
          </Glass>
          <Glass style={{ padding: "14px 16px", borderRadius: 14 }}>
            <div style={{ fontWeight: "var(--weight-emphasis)", fontSize: "var(--text-title)" }}>
              Updated to nightly
            </div>
            <div style={{ ...secondary, marginTop: 4 }}>Glass cards show the wallpaper through a lens at the rim.</div>
          </Glass>
          <div style={{ display: "flex", alignItems: "center", gap: 10, ...secondary }}>
            <span className="ui-glass" style={{ width: 22, height: 22, borderRadius: "50%" }} />
            Thinking
          </div>
        </div>
        <Glass
          role="menu"
          style={{ width: 200, padding: 5, borderRadius: 12, display: "grid", fontSize: "var(--text-control)" }}
        >
          {["Copy", "Quote in reply", "Fork from here", "Delete"].map((label) => (
            <div key={label} role="menuitem" style={{ padding: "5px 10px", borderRadius: 7 }}>
              {label}
            </div>
          ))}
        </Glass>
      </div>
      <Glass
        style={{
          position: "absolute",
          left: 28,
          right: 28,
          bottom: 28,
          minHeight: 92,
          padding: "14px 16px",
          borderRadius: 22,
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          fontSize: "var(--text-content)",
        }}
      >
        <span style={secondary}>Ask anything, @ to mention a file</span>
        <div style={{ display: "flex", gap: 8, fontSize: "var(--text-control)", ...secondary }}>
          <span>Plan</span>
          <span>Claude</span>
          <span style={{ marginInlineStart: "auto" }}>⌘↩</span>
        </div>
      </Glass>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.liquid-glass",
  title: "Liquid glass",
  area: "Pages",
  height: 520,
  covers: ["ui/glass/Glass.tsx#Glass"],
  load: async () => LiquidGlassGallery,
  experiment: {
    definition: chromiumGlassUnderlay,
    script: [
      {
        name: "glass over the transcript",
        run: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".ui-glass-floats")),
      },
    ],
  },
  variants: {
    lens: {
      note: "Lens: a clear center, the wallpaper bent inward at each rounded rim, a thin top-lit specular rim, and the lens's gloss (--glass-gloss 0.7): the rim facing the light catches a bright line, the far rim a faint one.",
      props: { mode: "lens", scheme: "dark" },
    },
    "lens-no-gloss": {
      note: "The lens as it was before the gloss (--glass-gloss 0), to compare.",
      props: { mode: "lens", scheme: "dark", look: { gloss: 0 } },
    },
    "liquid-thick": {
      note: "A thick lens: a deeper bend (34px), full gloss and a 6% zoom at the center.",
      props: { mode: "lens", scheme: "dark", look: { gloss: 1, magnify: 0.06, refraction: 34 } },
    },
    "liquid-prism": {
      note: "Spectrum with full gloss: the bend split per channel at the rim, lit along its top edge.",
      props: { mode: "spectrum", scheme: "dark", look: { gloss: 1 } },
    },
    "svg-displace": {
      note: "Chromium only: the SVG feDisplacementMap backdrop-filter bends the page's own pixels instead of the lens's canvas. In the app the wallpaper is native, behind the page, so this would bend only the transcript; it re-filters every glass on every scroll frame (design/glass.md).",
      props: { mode: "plain", scheme: "dark", svg: true },
    },
    "svg-displace-text": {
      note: "The SVG backdrop over transcript text: the letters under the composer bend at its rim.",
      props: { mode: "plain", scheme: "dark", transcript: true, svg: true },
    },
    "liquid-thick-light": {
      note: "The thick lens in a light theme.",
      props: { mode: "lens", scheme: "light", look: { gloss: 1, magnify: 0.06, refraction: 34 } },
    },
    plain: {
      note: "Plain glass: the blur glass from before the lens (tint, blur, thin rim, no specular).",
      props: { mode: "plain", scheme: "dark" },
    },
    spectrum: {
      note: "Spectrum: the lens plus a faint red and cyan split at the rim.",
      props: { mode: "spectrum", scheme: "dark" },
    },
    "lens-light": { note: "Lens in a light theme.", props: { mode: "lens", scheme: "light" } },
    "plain-light": { note: "Plain glass in a light theme.", props: { mode: "plain", scheme: "light" } },
    "spectrum-light": { note: "Spectrum in a light theme.", props: { mode: "spectrum", scheme: "light" } },
    "lens-text": {
      note: "Transcript text under the composer and a menu: the glass keeps a light frost (--glass-frost) over the lens, so text under it blurs instead of reading crisp.",
      props: { mode: "lens", scheme: "dark", transcript: true },
    },
    "plain-text": {
      note: "The same under plain glass: the shared 20px blur.",
      props: { mode: "plain", scheme: "dark", transcript: true },
    },
    "see-through-text": {
      note: "A see-through Chromium page (nothing painted behind it, as over the window glass): Chromium leaves the text under the menu and the composer crisp under the blurred copy, so they lay the theme surface under their tint (experiment chromium-glass-underlay; compare its arms). WebKit never draws it.",
      props: { mode: "plain", scheme: "dark", transcript: true, seeThrough: true },
    },
    "see-through-text-light": {
      note: "The same in a light theme.",
      props: { mode: "plain", scheme: "light", transcript: true, seeThrough: true },
    },
  },
});
