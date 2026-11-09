// l10n-allow-file: gallery fixtures for the glass-host package, not shipped UI.
// The glass-host package's own page (README.md): the web half driving a stand-in app. The gallery runs
// no AppKit, so the transport here draws each reported surface as the wallpaper frosted at its box
// (what GlassMaterialView's vibrancy path draws before macOS 26); the page draws the surface's content
// on top, as in an app. Each variant is one behavior of the API: a popover, a menu that moves and
// resizes, a chip, an app that answers late (the deadline fallback) and an app that refuses.
import { type CSSProperties, useEffect, useRef, useState } from "react";
import wallpaper from "../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../gallery/format";
import { createGlassHost, glassHostCss, type GlassLevel, type GlassSurfaceState } from "./index";
import { useGlassSurface } from "./react";

type App = "draws" | "late" | "refuses";
type Props = { level: GlassLevel; app: App; moves?: boolean };

const SIZE: Record<GlassLevel, { width: number; height: number; radius: number }> = {
  popover: { width: 300, height: 220, radius: 12 },
  menu: { width: 220, height: 168, radius: 10 },
  chip: { width: 140, height: 28, radius: 7 },
};
const TINT: Record<GlassLevel, string> = {
  popover: "rgba(30, 31, 36, 0.45)",
  menu: "rgba(30, 31, 36, 0.52)",
  chip: "rgba(30, 31, 36, 0.6)",
};

/** The stand-in app: one frosted box per reported surface. */
function StandInGlass({ surfaces }: { surfaces: GlassSurfaceState[] }) {
  return (
    <>
      {surfaces.map((surface) => (
        <div
          key={surface.id}
          aria-hidden="true"
          style={{
            position: "fixed",
            left: surface.left,
            top: surface.top,
            width: surface.right - surface.left,
            height: surface.bottom - surface.top,
            borderRadius: surface.radius,
            opacity: surface.opacity,
            overflow: "hidden",
            boxShadow: "var(--elevation-2)",
          }}
        >
          <div
            style={{
              position: "absolute",
              inset: 0,
              background: `url("${wallpaper}") ${-surface.left}px ${-surface.top}px / 100vw 100vh no-repeat`,
              /* glass-raw-blur-allow: the gallery's stand-in for the app's native glass, not a page glass */
              filter: "blur(30px) saturate(1.6)",
            }}
          />
          <div style={{ position: "absolute", inset: 0, background: TINT[surface.level] }} />
        </div>
      ))}
    </>
  );
}

const ROWS: Record<GlassLevel, string[]> = {
  popover: ["Environment · This Mac", "Context · 41% of 200k", "Pull request · #37601", "Subagents · 2 running"],
  menu: ["Ask before edits", "Edit automatically", "Plan mode", "Full access"],
  chip: ["Reply"],
};

function GlassHostGallery({ level, app, moves = false }: Props) {
  const [surfaces, setSurfaces] = useState<GlassSurfaceState[]>([]);
  const [host] = useState(() =>
    createGlassHost({
      deadlineMs: 50,
      transport: (next) => {
        if (app === "refuses") return Promise.reject(new Error("unknown call"));
        // A late app draws after the deadline: the surface already fell back and stays on its own look.
        const delay = app === "late" ? 120 : 0;
        return new Promise((resolve) =>
          setTimeout(() => {
            setSurfaces(next);
            resolve(undefined);
          }, delay),
        );
      },
    }),
  );
  useEffect(() => () => host.destroy(), [host]);
  const element = useRef<HTMLDivElement | null>(null);
  const phase = useGlassSurface(host, element, { level });
  const [shift, setShift] = useState(0);
  useEffect(() => {
    if (!moves) return;
    const timer = setInterval(() => setShift((value) => (value + 1) % 3), 900);
    return () => clearInterval(timer);
  }, [moves]);
  const size = SIZE[level];
  return (
    <div
      style={{
        position: "relative",
        height: 360,
        color: "var(--cmux-text)",
        fontSize: "var(--text-body)",
        background: `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`,
      }}
    >
      <style>{glassHostCss}</style>
      <StandInGlass surfaces={surfaces} />
      <div
        ref={element}
        data-testid="surface"
        style={
          {
            position: "absolute",
            left: 120 + shift * 60,
            top: 60,
            width: size.width + shift * 20,
            height: size.height,
            borderRadius: size.radius,
            padding: "var(--ds-space-2) 0",
            display: "grid",
            alignContent: "start",
            // The page's own look, which the surface keeps when it falls back.
            background: "rgba(30, 31, 36, 0.86)",
          } as CSSProperties
        }
      >
        {ROWS[level].map((row) => (
          <div key={row} style={{ padding: "var(--ds-space-1) var(--ds-space-4)" }}>
            {row}
          </div>
        ))}
      </div>
      <div style={{ position: "absolute", left: 16, bottom: 12, color: "var(--cmux-text-secondary)" }}>
        phase: {phase ?? "closed"}
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "glass-host.package",
  title: "Glass host (package)",
  area: "Pages",
  height: 380,
  covers: ["glass-host/index.ts#createGlassHost", "glass-host/react.ts#useGlassSurface"],
  load: async () => GlassHostGallery,
  variants: {
    popover: {
      note: "A popover on the app's glass: the page draws only its rows, over the glass the app drew at its box.",
      props: { level: "popover", app: "draws" },
    },
    "menu-moves": {
      note: "A menu that moves and grows every 0.9 s: the glass follows its box, one report per frame.",
      props: { level: "menu", app: "draws", moves: true },
    },
    chip: {
      note: "A chip (a floating button such as Reply) at the chip level.",
      props: { level: "chip", app: "draws" },
    },
    late: {
      note: "An app that answers after the 50 ms deadline: the surface shows on the page's own look and keeps it, with no pop when the app answers.",
      props: { level: "popover", app: "late" },
    },
    refuses: {
      note: "An app that does not know the call: every surface keeps the page's own look and the host stops reporting.",
      props: { level: "popover", app: "refuses" },
    },
  },
});
