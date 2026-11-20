// l10n-allow-file: gallery fixtures, not shipped UI.
// Popup and dialog corners, side by side with a popular macOS launcher's values (Leo, 2026-11-20: "the little
// curvature, border radius. I don't even know how you guys came up with it"). Each variant is one value of the
// Debug choices PopupCornerLook (glass.popupCorner) and DialogCornerLook (glass.dialogCorner): the host sets
// --cmux-popup-radius and --cmux-dialog-padding, which --ds-radius-popup and --ds-dialog-padding read, and this
// page sets them the same way. The dialog shows the native card's geometry (button corner + its padding,
// CmuxDialogMetrics.card) beside the web one (.ui-dialog.ui-glass), so a split shows as two corners.
import { type CSSProperties, useEffect } from "react";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../../gallery/format";

type Props = { popup?: number; dialog?: { native: number; web: number }; scheme?: "dark" | "light" };

const SCHEMES = {
  dark: { "--cmux-text": "rgb(236, 236, 240)", "--cmux-surface-solid": "rgb(30, 31, 36)" },
  light: { "--cmux-text": "rgb(28, 28, 32)", "--cmux-surface-solid": "rgb(250, 250, 252)" },
} as const;

function useRoot(popup: number | undefined, dialogPadding: number | undefined, scheme: "dark" | "light"): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("style");
    const vars: Record<string, string> = { ...SCHEMES[scheme] };
    if (popup !== undefined) vars["--cmux-popup-radius"] = `${popup}px`;
    if (dialogPadding !== undefined) vars["--cmux-dialog-padding"] = `${dialogPadding}px`;
    for (const [name, value] of Object.entries(vars)) root.style.setProperty(name, value);
    root.style.colorScheme = scheme;
    root.style.setProperty("background", `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
    root.setAttribute("data-cmux-see-through", "");
    return () => {
      root.removeAttribute("data-cmux-see-through");
      if (saved === null) root.removeAttribute("style");
      else root.setAttribute("style", saved);
    };
  }, [popup, dialogPadding, scheme]);
}

const ROWS = ["Copy", "Copy Link", "Open in New Tab", "Rename…", "Move to Group", "Delete"];

function Menu() {
  return (
    <div
      role="menu"
      aria-label="Corner sample"
      className="ui-popup ui-glass ui-menu"
      style={{ position: "absolute", left: 24, top: 24, width: 220, color: "var(--cmux-text)" }}
    >
      {ROWS.map((row, index) => (
        <div key={row} role="menuitem" className="ui-menu-item" data-highlighted={index === 1 ? "" : undefined}>
          {row}
        </div>
      ))}
    </div>
  );
}

function Card({ label, padding, web }: { label: string; padding: number; web: boolean }) {
  const style: CSSProperties = {
    position: "relative",
    inset: "auto",
    width: 300,
    margin: 0,
    padding,
    boxSizing: "border-box",
    color: "var(--cmux-text)",
    fontSize: "var(--text-body)",
    ...(web
      ? ({ "--ui-dialog-padding": `${padding}px` } as CSSProperties)
      : {
          borderRadius: `calc(var(--ds-radius-control) + ${padding}px)`,
          background: "color-mix(in srgb, var(--cmux-surface-solid) 55%, transparent)",
          boxShadow: "var(--elevation-2)",
          backdropFilter: "blur(var(--ds-transient-web-blur)) saturate(var(--ds-transient-web-saturation))",
        }),
  };
  return (
    <div role="dialog" aria-label={label} className={web ? "ui-dialog ui-glass" : undefined} style={style}>
      <div style={{ fontWeight: "var(--weight-emphasis)", marginBottom: 4 }}>{label}</div>
      <div style={{ opacity: 0.75, marginBottom: padding }}>Delete this chat? Its messages go too.</div>
      <div style={{ display: "flex", justifyContent: "flex-end", gap: 8 }}>
        <button type="button" className="ui-button ui-btn">
          Cancel
        </button>
        <button type="button" className="ui-button ui-btn" data-variant="primary">
          Delete
        </button>
      </div>
    </div>
  );
}

function CornerParityGallery({ popup, dialog, scheme = "dark" }: Props) {
  useRoot(popup, dialog?.web, scheme);
  if (popup !== undefined)
    return (
      <div style={{ position: "relative", height: 260 }}>
        <Menu />
      </div>
    );
  return (
    <div style={{ display: "flex", gap: 24, padding: 24, alignItems: "flex-start" }}>
      <Card label="Native card" padding={dialog!.native} web={false} />
      <Card label="Web dialog" padding={dialog!.web} web />
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.corner-parity",
  title: "Popup and dialog corners",
  area: "UI primitives",
  height: 300,
  covers: ["ui/Dialog.tsx#Dialog", "ui/Menu.tsx#MenuPopup"],
  load: async () => CornerParityGallery,
  styles: () => Promise.all([import("../ui.css"), import("../popupSurface.css")]),
  variants: {
    "popup-8": {
      note: "Before: 8, the pane radius popups took (#24589, no reason given). Rows 8 - 5 = 3, held at the grid's 5.",
      props: { popup: 8 },
    },
    "popup-12": { note: "12. Rows 12 - 5 = 7.", props: { popup: 12 } },
    "popup-18": {
      note: "Ships: 18, a popular macOS launcher's popover corner. Rows concentric: 18 - 5 = 13 on the menu grid, 18 - 4 = 14 elsewhere.",
      props: { popup: 18 },
    },
    "popup-18-light": { note: "Ships, light theme.", props: { popup: 18, scheme: "light" } },
    "dialog-20": {
      note: "Ships: padding 12 on both sides, 8 + 12 = 20, the reference launcher's dialog corner. Native and web are one corner.",
      props: { dialog: { native: 12, web: 12 } },
    },
    "dialog-24": { note: "Padding 16 on both sides: 8 + 16 = 24.", props: { dialog: { native: 16, web: 16 } } },
    "dialog-split": {
      note: "Before: native 8 + 16 = 24, web 8 + 24 = 32 (f1dd319c set the rule; the paddings were never matched).",
      props: { dialog: { native: 16, web: 24 } },
    },
  },
});
