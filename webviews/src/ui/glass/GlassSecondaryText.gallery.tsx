// l10n-allow-file: gallery fixtures, not shipped UI.
// Secondary text fitted per glass level (cmuxterm-hq docs/reading/2026-11-19-glass-field-study.md, gap 1).
// Leo: "Did we ever figure out why our "glass" was so stupid looking". The stage is the art and a
// transcript, and one menu-level popup and one chrome-level bar over it, each with a section label, a
// selected row and shortcuts in secondary text. "before" draws the secondary as the fixed 62% mix it was;
// "fitted" lets the glass levels draw theirs (--ds-glass-<level>-secondary).
import { type CSSProperties, useEffect } from "react";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../../gallery/format";

type Scheme = "dark" | "light";
type Look = "before" | "fitted";
type Props = { look: Look; scheme: Scheme };

const SCHEMES: Record<Scheme, Record<string, string>> = {
  dark: {
    "--cmux-surface-background": "transparent",
    "--cmux-surface-solid": "rgb(28, 28, 30)",
    "--cmux-text": "rgb(255, 255, 255)",
    "--cmux-text-secondary": "rgba(255, 255, 255, 0.62)",
  },
  light: {
    "--cmux-surface-background": "transparent",
    "--cmux-surface-solid": "rgb(245, 245, 247)",
    "--cmux-text": "rgb(29, 29, 31)",
    "--cmux-text-secondary": "rgba(29, 29, 31, 0.62)",
  },
};
const ROWS: [string, string][] = [
  ["New Tab", "⌘T"],
  ["Split Right", "⌘D"],
  ["Rename Workspace…", "⌘R"],
  ["Move to Window", "▸"],
  ["Copy Session Link", "⌥⌘C"],
  ["Close Workspace", "⇧⌘W"],
];
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

/** Before: the fixed 62% mix every surface read, whatever glass it sat on. */
const before = (look: Look): CSSProperties =>
  look === "before"
    ? ({ "--glass-secondary": "color-mix(in srgb, var(--cmux-text) 62%, transparent)" } as CSSProperties)
    : {};

function Menu({ look, scheme }: Props) {
  return (
    <div
      className="ui-popup ui-glass ui-menu"
      style={{
        position: "absolute",
        left: 24,
        top: 24,
        width: 300,
        boxSizing: "border-box",
        padding: "var(--ui-popup-padding)",
        borderRadius: "var(--ui-popup-radius)",
        color: "var(--cmux-text)",
        fontSize: "var(--text-body)",
        ...before(look),
      }}
    >
      <div style={{ color: "var(--ds-color-muted)", fontSize: "var(--text-detail)", padding: "4px 8px 6px" }}>
        WORKSPACE
      </div>
      {ROWS.map(([title, shortcut]) => (
        <div
          key={title}
          role="menuitem"
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
            height: "var(--ui-row-height)",
            padding: "0 var(--ds-space-2)",
            borderRadius: "var(--ui-row-radius)",
            background:
              title === "Split Right" ? (scheme === "dark" ? "rgb(255 255 255 / 12%)" : "rgb(0 0 0 / 7%)") : undefined,
          }}
        >
          <span>{title}</span>
          <span style={{ color: "var(--cmux-text-secondary)" }}>{shortcut}</span>
        </div>
      ))}
    </div>
  );
}

function Bar({ look }: { look: Look }) {
  return (
    <div
      className="ui-glass"
      style={{
        position: "absolute",
        left: 348,
        top: 24,
        width: 300,
        boxSizing: "border-box",
        padding: "8px 12px",
        borderRadius: 10,
        color: "var(--cmux-text)",
        fontSize: "var(--text-body)",
        display: "grid",
        gap: 6,
        ...before(look),
      }}
    >
      {["feat-cmux-next · 3 agents", "glass-land · reading", "glass-engine · idle"].map((row) => {
        const [name, detail] = row.split(" · ");
        return (
          <div key={row} style={{ display: "flex", justifyContent: "space-between" }}>
            <span>{name}</span>
            <span style={{ color: "var(--ds-color-muted)" }}>{detail}</span>
          </div>
        );
      })}
    </div>
  );
}

function GlassSecondaryTextGallery({ look, scheme }: Props) {
  useStage(scheme);
  return (
    <div style={{ position: "relative", height: 300, color: "var(--cmux-text)", fontSize: "var(--text-body)" }}>
      <div style={{ position: "absolute", left: 24, top: 8, right: 24, lineHeight: 1.6, opacity: 0.9 }}>
        {TRANSCRIPT.repeat(5)}
      </div>
      <Menu look={look} scheme={scheme} />
      <Bar look={look} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.glass-secondary-text",
  title: "Secondary text fitted per glass level",
  area: "Pages",
  height: 320,
  covers: ["ui/glass/glass.css", "pages/shared/desktop.css"],
  load: async () => GlassSecondaryTextGallery,
  variants: {
    before: {
      note: "Before: secondary text a fixed 62% mix on every glass (the lab: 4.38:1 on the menu over bright art, 3.43:1 on its selected row; chrome 2.88:1).",
      props: { look: "before", scheme: "dark" },
    },
    fitted: {
      note: "Fitted: the menu's secondary at 80%, the chrome's at 90% (dark), each the least that keeps 4.5:1 over black and white where the tint allows.",
      props: { look: "fitted", scheme: "dark" },
    },
    "fitted-light": {
      note: "Fitted, light: menu 74%, chrome 95%.",
      props: { look: "fitted", scheme: "light" },
    },
    "before-light": {
      note: "Before, light: 62% misses 4.5:1 even over a white page (the lab: 4.08:1).",
      props: { look: "before", scheme: "light" },
    },
  },
});
