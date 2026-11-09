// l10n-allow-file: gallery fixture data, not shipped UI.
// The pane's tab row in a tight pane through a close (Leo 2026-11-07, Trace-ID ask-11b77f340e: "you open a tab, or
// you close a tab, or you're selecting between tabs ... There's a bit of a hop, skip, and a jump"). Each variant draws
// the same four steps of his recording: three tabs with New Tab selected, the pointer on New Tab's close, New Tab gone
// with the chat selected, and GitHub selected. The tabs and the toolbar are the native strip's (PaneContentView); this
// draws their geometry so the variants can be compared side by side.
import { componentEntry } from "../../../gallery/format";
import "./header.css";

type Policy = "slot" | "follow" | "fold";
type Tab = { id: string; title: string };
type Step = { label: string; tabs: Tab[]; selected: string; chatShown: boolean; pointerOnClose?: boolean };

const GITHUB = { id: "github", title: "GitHub" };
const CHAT = { id: "chat", title: "studio-mac/menubar-chats-menu" };
const NEW = { id: "new", title: "New Tab" };
const STEPS: Step[] = [
  { label: "New Tab selected", tabs: [GITHUB, CHAT, NEW], selected: "new", chatShown: false },
  { label: "Pointer on its close", tabs: [GITHUB, CHAT, NEW], selected: "new", chatShown: false, pointerOnClose: true },
  { label: "Closed: the chat shows", tabs: [GITHUB, CHAT], selected: "chat", chatShown: true },
  { label: "GitHub selected", tabs: [GITHUB, CHAT], selected: "github", chatShown: false },
];

const WIDTH = 360;
const TOOL = 24;
const GAP = 4;
const CHAT_TOOLS = 4;
const MORE = TOOL + 8;

/// Where the tabs end at a step: the shipped slot keeps the widest tab's room; "follow" gives up only what the
/// selected tab takes; "fold" keeps one slot as wide as the "…" and folds the chat's tools into its menu.
function stripEnd(policy: Policy, step: Step): number {
  const chatRoom = CHAT_TOOLS * (TOOL + GAP) + 8;
  if (policy === "fold") return WIDTH - MORE;
  if (policy === "follow") return WIDTH - (step.chatShown ? chatRoom : MORE);
  return WIDTH - Math.max(chatRoom, MORE);
}

function Row({ policy, step }: { policy: Policy; step: Step }) {
  const end = stripEnd(policy, step);
  // Closing mode: the tabs keep their widths until the pointer leaves the strip.
  const tabWidth = Math.min(140, Math.floor(end / 3));
  const tools = step.chatShown && policy !== "fold" ? CHAT_TOOLS : 0;
  return (
    <div style={{ display: "grid", gap: 4 }}>
      <small style={{ opacity: 0.7 }}>{step.label}</small>
      <div
        style={{
          position: "relative",
          width: WIDTH,
          height: 32,
          borderBottom: "1px solid var(--ds-color-separator)",
        }}
      >
        <div style={{ position: "absolute", left: 0, top: 4, width: end, display: "flex", overflow: "hidden" }}>
          {step.tabs.map((tab) => (
            <div
              key={tab.id}
              style={{
                width: tabWidth,
                flex: "none",
                height: 24,
                padding: "0 8px",
                boxSizing: "border-box",
                display: "flex",
                alignItems: "center",
                gap: "var(--ds-space-1)",
                overflow: "hidden",
                whiteSpace: "nowrap",
                textOverflow: "ellipsis",
                borderRadius: 6,
                background: tab.id === step.selected ? "var(--ds-color-selection)" : undefined,
              }}
            >
              <span style={{ overflow: "hidden", textOverflow: "ellipsis", flex: 1 }}>{tab.title}</span>
              {tab.id === "new" && step.pointerOnClose ? <span aria-hidden>×</span> : null}
            </div>
          ))}
        </div>
        <div
          style={{
            position: "absolute",
            right: 8,
            top: 4,
            height: 24,
            display: "flex",
            gap: GAP,
            alignItems: "center",
          }}
        >
          {Array.from({ length: tools }, (_, index) => (
            <span
              key={index}
              style={{ width: TOOL, height: TOOL, borderRadius: 6, background: "var(--ds-color-hover)" }}
            />
          ))}
          {!step.chatShown || policy === "fold" ? <span style={{ width: TOOL, textAlign: "center" }}>⋯</span> : null}
        </div>
        <div
          title="where the tabs end"
          style={{
            position: "absolute",
            left: end,
            top: 0,
            bottom: 0,
            borderLeft: "1px dashed var(--ds-color-danger)",
          }}
        />
      </div>
    </div>
  );
}

function TabRowSlot({ policy }: { policy: Policy }) {
  return (
    <div style={{ display: "grid", gap: "var(--ds-space-3)", padding: 8, width: WIDTH }}>
      {STEPS.map((step) => (
        <Row key={step.label} policy={policy} step={step} />
      ))}
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.tab-row-slot",
  title: "Tab row trailing slot (narrow pane, close sequence)",
  area: "Agent pane",
  pane: true,
  height: 280,
  widths: { narrow: 380, normal: 420 },
  covers: ["agent-session/acpmux/header/tabRow.ts"],
  load: async () => TabRowSlot,
  variants: {
    slot: {
      note: "Shipped: one trailing slot as wide as the widest tab's need; the red line never moves and the chat's tools land in a slot that was already there.",
      props: { policy: "slot" },
    },
    follow: {
      note: "Before: the strip gives up only what the selected tab takes, so every select, open and close moves the tabs' end and the tools jump.",
      props: { policy: "follow" },
    },
    fold: {
      note: "Considered: a slot only as wide as the ⋯, the chat's tools always in its menu. Stable, but the tools leave the row in every pane.",
      props: { policy: "fold" },
    },
  },
});
