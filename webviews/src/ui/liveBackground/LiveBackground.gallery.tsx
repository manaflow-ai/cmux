// l10n-allow-file: gallery fixtures, not shipped UI.
// A live background (liveBackground.ts) behind transcript text, a menu and the composer's glass, as
// the agent pane draws it under the live-background experiment.
import { useEffect } from "react";
import { componentEntry } from "../../gallery/format";
import { Glass } from "../glass/Glass";
import { installLiveBackground, type LiveBackgroundStyle } from "./liveBackground";

type Scheme = "dark" | "light";
type Props = { style: LiveBackgroundStyle; scheme: Scheme; reduced?: boolean };

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

function useLiveBackground(style: LiveBackgroundStyle, scheme: Scheme, reduced: boolean): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("style");
    const savedTheme = root.getAttribute("data-theme");
    const savedMotion = root.getAttribute("data-cmux-motion");
    for (const [name, value] of Object.entries(SCHEMES[scheme])) root.style.setProperty(name, value);
    root.style.colorScheme = scheme;
    root.setAttribute("data-theme", scheme);
    if (reduced) root.setAttribute("data-cmux-motion", "reduced");
    root.style.setProperty("background", "transparent", "important");
    const live = installLiveBackground(document, style);
    return () => {
      live?.uninstall();
      if (saved === null) root.removeAttribute("style");
      else root.setAttribute("style", saved);
      if (savedTheme === null) root.removeAttribute("data-theme");
      else root.setAttribute("data-theme", savedTheme);
      if (savedMotion === null) root.removeAttribute("data-cmux-motion");
      else root.setAttribute("data-cmux-motion", savedMotion);
    };
  }, [style, scheme, reduced]);
}

const PARAGRAPHS = [
  "I traced the stutter to the transcript's scroll handler: every wheel event read the composer's height, which forced a layout right after the virtualizer moved its rows.",
  "The fix reads the height once per frame from the resize observer that already watches the composer, and the handler only marks the frame dirty.",
  "Two tests cover it: one scrolls a long fixture and counts long frames, the other checks that the composer's height is read at most once per frame.",
];

function LiveBackgroundGallery({ style, scheme, reduced = false }: Props) {
  useLiveBackground(style, scheme, reduced);
  return (
    <div
      style={{
        position: "relative",
        minHeight: "100vh",
        padding: "24px 32px",
        boxSizing: "border-box",
        fontSize: "var(--text-content)",
        lineHeight: "var(--text-content--line-height)",
        color: "var(--cmux-text)",
      }}
    >
      {PARAGRAPHS.map((paragraph) => (
        <p key={paragraph.slice(0, 24)} style={{ margin: "0 0 14px", maxWidth: 640 }}>
          {paragraph}
        </p>
      ))}
      <Glass
        className="ui-glass-floats"
        style={{ justifySelf: "end", maxWidth: 300, marginInlineStart: "auto", padding: "10px 14px", borderRadius: 18 }}
      >
        Can the background move without pulling my eye off the text?
      </Glass>
      <Glass
        className="ui-glass-floats"
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
        }}
      >
        <span style={{ color: "var(--cmux-text-secondary)" }}>Ask anything, @ to mention a file</span>
        <div style={{ display: "flex", gap: 8, fontSize: "var(--text-control)", color: "var(--cmux-text-secondary)" }}>
          <span>Plan</span>
          <span>Claude</span>
          <span style={{ marginInlineStart: "auto" }}>⌘↩</span>
        </div>
      </Glass>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.live-background",
  title: "Live background",
  area: "Pages",
  experimental: true,
  height: 480,
  covers: ["ui/liveBackground/liveBackground.ts#installLiveBackground"],
  keywords: ["background", "wallpaper", "shader", "aurora", "animated", "live"],
  load: async () => LiveBackgroundGallery,
  variants: {
    aurora: {
      note: "Aurora: accent bands sway and fold slowly over a deep field, at half resolution and at most 30 fps.",
      props: { style: "aurora", scheme: "dark" },
    },
    drift: {
      note: "Drift: four soft palette blobs wander, a mesh gradient in motion.",
      props: { style: "drift", scheme: "dark" },
    },
    grain: { note: "Grain: drift with a fine film grain under 3%.", props: { style: "grain", scheme: "dark" } },
    "aurora-light": { note: "Aurora in a light theme.", props: { style: "aurora", scheme: "light" } },
    "drift-light": { note: "Drift in a light theme.", props: { style: "drift", scheme: "light" } },
    "drift-reduced-motion": {
      note: "Reduce Motion (or motion off): one still frame, no loop.",
      props: { style: "drift", scheme: "dark", reduced: true },
    },
  },
});
