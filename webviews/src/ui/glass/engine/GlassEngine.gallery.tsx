// l10n-allow-file: gallery fixtures, not shipped UI.
// The glass engine (engineRenderer.ts) against the lens it upgrades, over the wallpaper the app draws
// natively behind the page. As in LiquidGlass.gallery.tsx, the wallpaper is the page background and
// the same still goes through `cmuxTheme.backdrop`, so the engine takes the path it takes in the app;
// `engine` puts the host's ask (data-glass-engine, the Debug choice Glass Engine) on <html>. The busy
// still is drawn here: fine stripes, a checker and dark and light text bands, the worst backdrop a
// glass meets, so the bend, the rim and the adaptive veil read at a glance. `moving` slides the
// composer and sweeps a pointer past the menu, so the flex and the pointer light show.
import { useEffect, useMemo } from "react";
import wallpaper from "../../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../../../gallery/format";
import { Glass } from "../Glass";
import { glassEngine } from "./glassEngine.experiment";

type Scheme = "dark" | "light";
type Props = {
  engine: boolean;
  scheme: Scheme;
  /** The busy still instead of the photo. */
  busy?: boolean;
  /** Spectrum: the engine splits the rim per channel. */
  spectrum?: boolean;
  /** A grid of small glass, as many panes' chips and pills at once. */
  many?: boolean;
  /** The composer slides and a pointer sweeps past the menu. */
  moving?: boolean;
};

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
const TINT: Record<Scheme, string> = { dark: "rgba(0, 0, 0, 0.18)", light: "rgba(255, 255, 255, 0.16)" };

/** The busy still: stripes, a checker, and bands of dark and light text. */
function busyStill(): string {
  const canvas = document.createElement("canvas");
  canvas.width = 1024;
  canvas.height = 640;
  const context = canvas.getContext("2d");
  if (!context) return wallpaper;
  const hues = ["#ff4d6d", "#ffb703", "#3a86ff", "#06d6a0", "#8338ec", "#fb5607"];
  for (let x = 0; x < canvas.width; x += 16) {
    context.fillStyle = hues[(x / 16) % hues.length]!;
    context.fillRect(x, 0, 8, canvas.height);
  }
  for (let y = 220; y < 420; y += 20)
    for (let x = 0; x < canvas.width; x += 20) {
      context.fillStyle = (x + y) % 40 === 0 ? "#111" : "#f4f4f4";
      context.fillRect(x, y, 20, 20);
    }
  context.font = "600 22px system-ui, sans-serif";
  for (let row = 0; row < 6; row++) {
    const dark = row % 2 === 0;
    context.fillStyle = dark ? "#121214" : "#fafafa";
    context.fillRect(0, 440 + row * 32, canvas.width, 32);
    context.fillStyle = dark ? "#fafafa" : "#121214";
    context.fillText("glass engine  refraction  rim light  adaptive veil  motion  ".repeat(3), 8, 463 + row * 32);
  }
  return canvas.toDataURL("image/png");
}

type BackdropHost = { cmuxTheme?: { backdrop?: (partial: unknown) => void } };

function useStage({ engine, scheme, busy = false, spectrum = false }: Props, still: string): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("style");
    const savedGlass = root.getAttribute("data-glass");
    const savedTheme = root.getAttribute("data-theme");
    for (const [name, value] of Object.entries(SCHEMES[scheme])) root.style.setProperty(name, value);
    root.style.colorScheme = scheme;
    root.setAttribute("data-theme", scheme);
    root.setAttribute("data-glass", spectrum ? "spectrum" : "lens");
    if (engine) root.setAttribute("data-glass-engine", "");
    const tint = TINT[scheme];
    root.style.setProperty(
      "background",
      `linear-gradient(${tint}, ${tint}) fixed, url("${still}") 0 0 / 100vw 100vh no-repeat fixed`,
      "important",
    );
    const send = () =>
      (window as unknown as BackdropHost).cmuxTheme?.backdrop?.({
        image: still,
        key: `gallery-glass-engine-${busy ? "busy" : "photo"}`,
        rect: { x: 0, y: 0, width: root.clientWidth, height: root.clientHeight },
        blur: 0,
        tint,
      });
    send();
    window.addEventListener("resize", send);
    return () => {
      window.removeEventListener("resize", send);
      (window as unknown as BackdropHost).cmuxTheme?.backdrop?.({ image: null, key: null });
      root.removeAttribute("data-glass-engine");
      if (saved === null) root.removeAttribute("style");
      else root.setAttribute("style", saved);
      if (savedGlass === null) root.removeAttribute("data-glass");
      else root.setAttribute("data-glass", savedGlass);
      if (savedTheme === null) root.removeAttribute("data-theme");
      else root.setAttribute("data-theme", savedTheme);
    };
  }, [engine, scheme, busy, spectrum, still]);
}

/** Slides the composer and sweeps a pointer past the menu, once a second, while mounted. */
function useMotion(moving: boolean): void {
  useEffect(() => {
    if (!moving) return;
    let frame = 0;
    const start = performance.now();
    const tick = (now: number) => {
      const t = ((now - start) % 2400) / 2400;
      const composer = document.querySelector<HTMLElement>("[data-engine-composer]");
      if (composer) composer.style.transform = `translateY(${Math.round(Math.sin(t * Math.PI * 2) * 24)}px)`;
      const x = 120 + 520 * t;
      document.dispatchEvent(new PointerEvent("pointermove", { clientX: x, clientY: 110, bubbles: true }));
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [moving]);
}

const text = { color: "var(--cmux-text)" } as const;
const secondary = { color: "var(--cmux-text-secondary)" } as const;
const menu = { padding: 5, borderRadius: 12, display: "grid", fontSize: "var(--text-control)" } as const;

function Many() {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: 12, padding: 24 }}>
      {Array.from({ length: 30 }, (_, index) => (
        <Glass
          key={index}
          style={{ height: 52, borderRadius: index % 3 === 0 ? 999 : 12, padding: "8px 12px", ...text }}
        >
          Pane {index + 1}
        </Glass>
      ))}
    </div>
  );
}

function GlassEngineGallery(props: Props) {
  const still = useMemo(() => (props.busy ? busyStill() : wallpaper), [props.busy]);
  useStage(props, still);
  useMotion(props.moving === true);
  if (props.many) return <Many />;
  return (
    <div
      style={{
        position: "relative",
        minHeight: "100vh",
        padding: 24,
        boxSizing: "border-box",
        fontSize: "var(--text-body)",
        lineHeight: "var(--text-body--line-height)",
        ...text,
      }}
    >
      <div style={{ display: "flex", gap: 24, alignItems: "flex-start", flexWrap: "wrap" }}>
        <div style={{ display: "grid", gap: 12, width: 320 }}>
          <Glass style={{ justifySelf: "end", maxWidth: 260, padding: "8px 12px", borderRadius: 16 }}>
            Does the rim bend what is behind it?
          </Glass>
          <Glass style={{ padding: "12px 16px", borderRadius: 12 }}>
            <div style={{ fontWeight: "var(--weight-emphasis)", fontSize: "var(--text-title)" }}>
              Updated to nightly
            </div>
            <div style={{ ...secondary, marginTop: 4 }}>
              The veil comes up only where the wallpaper fights the text.
            </div>
          </Glass>
          <div style={{ display: "flex", alignItems: "center", gap: 8, ...secondary }}>
            <span className="ui-glass" style={{ width: 28, height: 28, borderRadius: "50%" }} />
            Thinking
          </div>
        </div>
        <Glass role="menu" style={{ width: 200, ...menu }}>
          {["Copy", "Quote in reply", "Fork from here", "Delete"].map((label) => (
            <div key={label} role="menuitem" style={{ padding: "4px 8px", borderRadius: 6 }}>
              {label}
            </div>
          ))}
        </Glass>
      </div>
      <Glass
        data-engine-composer=""
        style={{
          position: "absolute",
          left: 24,
          right: 24,
          bottom: 24,
          minHeight: 92,
          padding: "12px 16px",
          borderRadius: 16,
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
  id: "ui.glass-engine",
  title: "Glass engine",
  area: "Pages",
  height: 520,
  covers: ["ui/glass/Glass.tsx#Glass"],
  load: async () => GlassEngineGallery,
  experiment: {
    definition: glassEngine,
    script: [
      { name: "glass over the wallpaper", run: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".ui-glass")) },
    ],
  },
  variants: {
    engine: {
      note: "The engine over the photo, dark: Snell refraction through a superellipse rim (the edge compresses and bends the wallpaper, the middle stays true), a Fresnel sheen and a two-light rim, and a lighter tint, since the photo under it is calm.",
      props: { engine: true, scheme: "dark" },
    },
    "engine-light": {
      note: "The engine in a light theme: the far rim shades a little, so the rim still reads over a bright wallpaper.",
      props: { engine: true, scheme: "light" },
    },
    "engine-busy": {
      note: "The worst backdrop: stripes, a checker and text bands in both inks. The veil rises only over the bands whose ink matches the text, and the stripes bend at every rim.",
      props: { engine: true, scheme: "dark", busy: true },
    },
    "engine-busy-light": {
      note: "The busy backdrop in a light theme.",
      props: { engine: true, scheme: "light", busy: true },
    },
    "engine-prism": {
      note: "The engine under Spectrum: each channel refracts by its own index, on the rim only.",
      props: { engine: true, scheme: "dark", busy: true, spectrum: true },
    },
    "engine-moving": {
      note: "Motion: the composer slides (it flexes and its rim brightens while it moves, then settles) and a pointer sweeps past the menu (the key light swings toward it).",
      props: { engine: true, scheme: "dark", busy: true, moving: true },
    },
    "engine-many": {
      note: "Thirty small glass at once, as many panes' pills and chips: one canvas, one texel per glass pixel.",
      props: { engine: true, scheme: "dark", many: true },
    },
    lens: {
      note: "The lens as it ships, over the same photo, to compare.",
      props: { engine: false, scheme: "dark" },
    },
    "lens-busy": {
      note: "The lens as it ships over the busy backdrop.",
      props: { engine: false, scheme: "dark", busy: true },
    },
  },
});
