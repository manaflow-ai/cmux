// l10n-allow-file: gallery fixtures (sample machine, folder and chat names), not shipped UI.
//
// Session Info's cloud controls and the sidebar mark (RFD 0075). Leo, 2026-11-23: "especially in
// the session info. remote control LITERALLY DOES NOTHING ... we can replace that area with our
// cloud... paradigms", and "a slight mark or something sweet and unobtrusive but informative in the
// sidebar". The Environment list is the real one, with the cloud rows where Remote Control was.
// The sidebar's rows are native (CmuxNextSidebar), so the mark here is a sketch of them for
// choosing a look; the Swift row follows the pick.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { EnvironmentSection } from "../session-info/EnvironmentSection";
import { SessionInfoPanel } from "../session-info/SessionInfo";
import { CloudToggle } from "./CloudToggle";
import { clicked, type HybridLook, type HybridView } from "./hybridModel";
import type { SessionInfoCloudLook } from "./SessionInfoCloud";

type Props =
  | { stage: "info"; look: SessionInfoCloudLook; state: "off" | "on" | "waiting"; toggleLook?: HybridLook }
  | { stage: "sidebar"; mark: "cloud" | "dot" | "word"; look: HybridLook };

const VIEWS: Record<"off" | "on" | "waiting", HybridView> = {
  off: { lit: false, pin: "auto", at: "local", used: 1, total: 3 },
  on: { lit: true, pin: "auto", at: "local", used: 2, total: 3 },
  waiting: { lit: false, waiting: true, pin: "auto", at: "local", used: 3, total: 3 },
};

function Info({ look, state, toggleLook }: Extract<Props, { stage: "info" }>) {
  const [view, setView] = useState(VIEWS[state]);
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <SessionInfoPanel width={300} placement="overlay">
        <EnvironmentSection
          summary={{
            sessionId: "hybrid-gallery",
            hostKind: "local",
            cwd: "/Users/demo/Projects/atlas",
            branch: "feat/live-view",
          }}
          machineName="Studio Mac"
          repository="demo/atlas"
          edits={{ additions: 42, deletions: 7 }}
          onOpenChanges={() => undefined}
          cloud={{
            view,
            setLit: () => setView(clicked),
            setPin: (pin) => setView((now) => ({ ...now, pin })),
          }}
          cloudLook={look}
          cloudToggleLook={toggleLook}
        />
      </SessionInfoPanel>
    </div>
  );
}

const ROWS = [
  { title: "Fix the flaky login test", kept: true },
  { title: "Draft the release notes", kept: false },
  { title: "Migrate billing tables", kept: true },
  { title: "Rename the settings keys", kept: false },
];

function Sidebar({ mark, look }: Extract<Props, { stage: "sidebar" }>) {
  const lit: HybridView = { lit: true, pin: "auto", at: "cloud", used: 2, total: 3 };
  return (
    <ul style={{ listStyle: "none", margin: 0, padding: 8, width: 240, display: "grid", gap: 4 }}>
      {ROWS.map((row) => (
        <li
          key={row.title}
          style={{ display: "flex", alignItems: "center", gap: 8, height: 28, padding: "0 8px", borderRadius: 6 }}
        >
          <span
            style={{
              flex: "1 1 auto",
              minWidth: 0,
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
            }}
          >
            {row.title}
          </span>
          {row.kept && mark === "cloud" && (
            <span className="acpmux-hybrid-mark">
              <CloudToggle view={lit} look={look} form="icon" onChange={() => undefined} />
            </span>
          )}
          {row.kept && mark === "dot" && <span className="acpmux-hybrid-dot" data-look={look} aria-hidden="true" />}
          {row.kept && mark === "word" && <span className="acpmux-hybrid-word">Kept running</span>}
        </li>
      ))}
    </ul>
  );
}

function Stage(props: Props) {
  return props.stage === "info" ? <Info {...props} /> : <Sidebar {...props} />;
}

export default componentEntry<Props>({
  id: "agent-pane.hybrid-session-info-cloud",
  title: "Hybrid chats: Session Info and the sidebar mark",
  area: "Agent pane",
  pane: true,
  height: 300,
  widths: { narrow: 320, normal: 420 },
  covers: ["agent-session/acpmux/hybrid/SessionInfoCloud.tsx"],
  load: async () => Stage,
  variants: {
    "info-where": {
      note: "Chosen: Keep Running as a switch where Remote Control was, with the plan's slots, and Runs On under it for the two pins (Only in Cloud, Only on This Mac).",
      props: { stage: "info", look: "where", state: "off" },
    },
    "info-where-on": { note: "The chosen look, on.", props: { stage: "info", look: "where", state: "on" } },
    "info-where-waiting": {
      note: "The chosen look with every slot taken: the switch is on, the tooltip says it waits.",
      props: { stage: "info", look: "where", state: "waiting" },
    },
    "info-switch": {
      note: "Alternative: the switch alone. One row, as Remote Control was; the pins live only in the chat menu.",
      props: { stage: "info", look: "switch", state: "on" },
    },
    "info-button": {
      note: "Alternative: the composer's own cloud button as the row's control, so both places show the same object.",
      props: { stage: "info", look: "button", state: "on", toggleLook: "rainbow" },
    },
    "info-button-sky": {
      note: "The button alternative in the Sky look.",
      props: { stage: "info", look: "button", state: "on", toggleLook: "sky" },
    },
    "sidebar-cloud": {
      note: "Chosen: the lit cloud at the end of kept-running rows only. Rows that are off draw nothing, so it never says where a chat runs (design/sidebar.md: no machine glyph).",
      props: { stage: "sidebar", mark: "cloud", look: "rainbow" },
    },
    "sidebar-cloud-sky": {
      note: "The cloud mark in the Sky look.",
      props: { stage: "sidebar", mark: "cloud", look: "sky" },
    },
    "sidebar-dot": {
      note: "Alternative: a 6 px rainbow dot. Quieter, but it reads as unread or status, which the row already has.",
      props: { stage: "sidebar", mark: "dot", look: "rainbow" },
    },
    "sidebar-word": {
      note: "Alternative: the words. Clear to a new person, heavy on every row at 240 px.",
      props: { stage: "sidebar", mark: "word", look: "rainbow" },
    },
  },
});
