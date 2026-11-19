// l10n-allow-file: gallery fixture data, not shipped UI.
// The tab strip's looks under experiments.tabBarStyle (Settings > Experimental > Tab Bar, taste build 3): off (the
// shipped strip), glass, fused and underline, each with 3 tabs and with 12. The strip is native (PaneContentView);
// this draws its geometry so the arms can be compared side by side, as TabRowSlot.gallery.tsx does.
import { componentEntry } from "../../../gallery/format";

type Style = "off" | "glass" | "fused" | "underline";
type Props = { style: Style; count: number };

const TAB_TITLES = [
  "studio-mac/menubar-chats-menu",
  "GitHub",
  "README.md",
  "zsh: ~/src/cmux",
  "Pull request #4812",
  "cargo test",
  "design notes",
  "tabRow.ts",
  "Settings",
  "build log",
  "fleet status",
  "Changelog",
  "header.css",
  "release checklist",
  "Inbox",
  "deploy preview",
  "PaneContentView.swift",
  "npm run dev",
  "History",
  "New Tab",
];

function Label({ text, reserveBold }: { text: string; reserveBold: boolean }) {
  if (!reserveBold) return <span className="ttb-label">{text}</span>;
  // The bold copy holds the cell's width so selecting a tab never moves its text.
  return (
    <span className="ttb-label-stack">
      <span className="ttb-label">{text}</span>
      <span className="ttb-label" aria-hidden>
        {text}
      </span>
    </span>
  );
}

function TabStripStyle({ style, count }: Props) {
  const tabs = TAB_TITLES.slice(0, count);
  const selected = Math.min(1, count - 1);
  return (
    <div className="ttb-window" data-style={style}>
      <div className="ttb-strip" role="tablist">
        <div className="ttb-tabs">
          {tabs.map((title, index) => (
            <div
              key={title}
              className="ttb-tab"
              role="tab"
              aria-selected={index === selected}
              data-selected={index === selected ? "" : undefined}
              title={title}
            >
              <span className="ttb-icon" aria-hidden />
              <Label text={title} reserveBold={style === "underline"} />
            </div>
          ))}
        </div>
        <span className="ttb-plus" aria-label="New Tab">
          +
        </span>
      </div>
      <div className="ttb-content">
        <b>{tabs[selected]}</b> is the selected tab; its content sheet starts here.
      </div>
    </div>
  );
}

function TabBarStyles(props: Props) {
  return (
    <div className="ttb-sheet-stage">
      <div className="ttb-caption">
        {props.style} · {props.count} tabs
      </div>
      <TabStripStyle {...props} />
    </div>
  );
}

const NOTES: Record<Style, string> = {
  off: "Shipped: a rounded selection fill on the bar and a plain + button.",
  glass:
    "Every tab in one translucent glass capsule with a hairline edge, the selected tab a lighter inner pill; the + its own round glass button.",
  fused:
    "Inactive tabs flat on a tinted bar with thin separators; the selected tab takes the sheet's color and runs into it.",
  underline:
    "No fills: a hairline under the strip, the selected label bold over a 2px accent rule; the bold width is reserved.",
};

const STYLES: Style[] = ["off", "glass", "fused", "underline"];

export default componentEntry<Props>({
  id: "agent-pane.tab-bar-styles",
  title: "Tab bar styles (experiments.tabBarStyle)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 200,
  widths: { narrow: 420, normal: 760, wide: 1200 },
  keywords: ["tab strip", "glass", "fused", "underline", "taste"],
  covers: ["agent-session/acpmux/header/tabRow.ts"],
  load: async () => TabBarStyles,
  styles: () => import("./TabStrip.gallery.css"),
  variants: Object.fromEntries(
    STYLES.flatMap((style) =>
      [3, 12].map((count) => [`${style}-${count}`, { note: NOTES[style], props: { style, count } }]),
    ),
  ),
});
