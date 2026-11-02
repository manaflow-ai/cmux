// l10n-allow-file: gallery mocks of menu layouts (sample labels), not shipped UI.
// Where the chat's Transcript view goes (conversation/transcriptView.ts; Leo, 2026-10-29: "i like
// these kinds of settings from claude code desktop..."), three layouts side by side:
//   A (Recommended, shipped): a "Transcript view ›" submenu in the ··· menu, as Claude Code
//     desktop's chat menu: Normal, Thinking, Verbose with a check, then "Make … the default", then
//     Wrap lines (every command's output; Verbose opens every Shell block, so it lives here once)
//     and Text & Width…. It takes Text & Width's row, so the full-height menu grows by none and Archive
//     stays on screen; the choice is two clicks away, the default beside it.
//   B: the three views inline in the ··· menu under a "Transcript view" label: one click, but the
//     menu grows by four rows that most opens never use.
//   C: a segmented control in the Text & Width popover: beside the other look settings, but a
//     transcript view is not a look, and the popover is three clicks away.
import type { ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";

type Layout = "submenu" | "inline" | "popover";

const MENU = ["Rename", "Pin", "—", "New side chat", "Fork", "—", "Copy", "—"];
const VIEWS = ["Normal", "Thinking", "Verbose"];

const surface = {
  width: 240,
  padding: 6,
  borderRadius: 10,
  background: "var(--agent-surface-elevated, #2b2b2b)",
  color: "var(--agent-text, #eee)",
  boxShadow: "0 6px 24px rgb(0 0 0 / 0.25)",
} as const;
const rule = { height: 1, margin: "4px 6px", background: "color-mix(in srgb, currentColor 12%, transparent)" };
const item = { padding: "4px 8px", borderRadius: 6, display: "flex", justifyContent: "space-between" } as const;
const lit = { ...item, background: "color-mix(in srgb, currentColor 10%, transparent)" };

function Rows({ rows }: { rows: readonly string[] }) {
  return rows.map((row, index) =>
    row === "—" ? (
      // oxlint-disable-next-line react/no-array-index-key
      <div key={index} style={rule} />
    ) : (
      // oxlint-disable-next-line react/no-array-index-key
      <div key={index} style={item}>
        {row}
      </div>
    ),
  );
}

function Menu({ children }: { children?: ReactNode }) {
  return (
    <div className="text-body" style={surface}>
      <Rows rows={MENU} />
      {children}
    </div>
  );
}

const check = (on: boolean) => <span style={{ width: 14, display: "inline-block" }}>{on ? "✓" : ""}</span>;

function Layouts({ layout }: { layout: Layout }) {
  if (layout === "submenu")
    return (
      <div style={{ display: "flex", gap: 4, alignItems: "flex-end", padding: 16 }} data-transcript-view-menu>
        <Menu>
          <div style={lit}>
            <span>Transcript view</span>
            <span>›</span>
          </div>
          <div style={rule} />
          <div style={item}>
            <span>Archive</span>
            <kbd>A</kbd>
          </div>
        </Menu>
        <div className="text-body" style={surface}>
          {VIEWS.map((view) => (
            <div key={view} style={{ ...item, justifyContent: "flex-start", gap: 6 }}>
              {check(view === "Normal")}
              {view}
            </div>
          ))}
          <div style={rule} />
          <div style={{ ...item, opacity: 0.5 }}>Make Normal the default</div>
          <div style={rule} />
          <div style={{ ...item, justifyContent: "flex-start", gap: 6 }}>
            {check(true)}
            Wrap lines
          </div>
          <div style={item}>Text & Width…</div>
        </div>
      </div>
    );
  if (layout === "inline")
    return (
      <div style={{ padding: 16 }} data-transcript-view-menu>
        <Menu>
          <div style={item}>Text & Width…</div>
          <div style={rule} />
          <div style={{ ...item, opacity: 0.6, fontSize: "0.85em" }}>Transcript view</div>
          {VIEWS.map((view) => (
            <div key={view} style={{ ...item, justifyContent: "flex-start", gap: 6 }}>
              {check(view === "Normal")}
              {view}
            </div>
          ))}
          <div style={item}>Make Normal the default</div>
        </Menu>
      </div>
    );
  return (
    <div style={{ display: "flex", gap: 12, alignItems: "flex-start", padding: 16 }} data-transcript-view-menu>
      <Menu>
        <div style={lit}>Text & Width…</div>
      </Menu>
      <div className="text-body" style={{ ...surface, width: 280, padding: 12 }}>
        <div style={{ marginBottom: 8 }}>Transcript view</div>
        <div style={{ display: "flex", gap: 2, padding: 2, borderRadius: 7, background: "rgb(127 127 127 / 0.15)" }}>
          {VIEWS.map((view) => (
            <span
              key={view}
              style={{
                flex: 1,
                textAlign: "center",
                padding: "3px 0",
                borderRadius: 5,
                background: view === "Normal" ? "rgb(127 127 127 / 0.35)" : undefined,
              }}
            >
              {view}
            </span>
          ))}
        </div>
        <div style={{ marginTop: 10, opacity: 0.6 }}>Width · Font · Size · Line height…</div>
      </div>
    </div>
  );
}

export default componentEntry<{ layout: Layout }>({
  id: "agent-pane.transcript-view-menu",
  title: "Transcript view in the ··· menu",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/header/transcriptViewRow.ts#transcriptViewRow"],
  anchors: [{ selector: "[data-transcript-view-menu]" }],
  pane: true,
  load: () => Promise.resolve(Layouts),
  variants: {
    "a-submenu-recommended": {
      props: { layout: "submenu" },
      note: "Recommended, shipped: a Transcript view submenu with a check on the chat's view, Make … the default and Text & Width…, as Claude Code desktop's chat menu; the menu grows by no row",
    },
    "b-inline-group": {
      props: { layout: "inline" },
      note: "The views inline under a label: one click, but four more rows on every open",
    },
    "c-display-popover": {
      props: { layout: "popover" },
      note: "A segmented control in Text & Width: beside the look settings, but three clicks away and not a look",
    },
  },
});
