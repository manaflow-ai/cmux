// l10n-allow-file: gallery fixture (sample commands, output and agent names), not shipped UI.
//
// A capture board for background activity proposals. It deliberately keeps the four placements
// together so a review can compare the same live work in a pinned panel, after the latest message,
// a compact pill and a side panel. The real app owns the process/session lifecycle; this board is
// data-only and never starts a process or sends a session request.
import { createContext, useContext, useEffect, useRef, useState } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { SubagentTray } from "../subagents/SubagentTray";
import type { TrayItem } from "../subagents/runningTray";

type Surface = "pinned-live-tail" | "after-latest-message" | "compact-pill" | "side-panel" | "duration-columns";
type Mode = "light" | "dark";

type Props = {
  surface: Surface;
  mode: Mode;
};

type ActivityState = { stopped: Set<string>; stop: (id: string) => void };
const ActivityStateContext = createContext<ActivityState>({ stopped: new Set(), stop: () => {} });

type Command = {
  id: string;
  command: string;
  state: "running" | "failed";
  detail: string;
};

const COMMANDS: Command[] = [
  {
    id: "dev-server",
    command: "bun run webviews:dev",
    state: "running",
    detail: "serving gallery at 127.0.0.1:4210",
  },
  {
    id: "background-tests",
    command: "bun test test/agent-pane-background-tasks.test.tsx",
    state: "running",
    detail: "14 tests collected · 11 passed",
  },
  {
    id: "complexity",
    command: "bun run lint:complexity",
    state: "failed",
    detail: "1 function exceeds the existing baseline",
  },
];

const COMMAND_OUTPUTS: Record<string, string[]> = {
  "dev-server": [
    "$ bun run webviews:dev",
    "vite v6.3.1 dev server running",
    "  ➜  Local:   http://127.0.0.1:4210/gallery/",
    "  ➜  Network: use --host to expose",
    "[gallery] warming agent-pane entries…",
    "[gallery] loaded 182 entries in 1.42s",
    "[hmr] watching webviews/src/agent-session",
    "[hmr] waiting for file changes",
    "[agent] 2 commands running · 101 subagents done",
    "█ live output · following newest line",
  ],
  "background-tests": [
    "$ bun test test/agent-pane-background-tasks.test.tsx",
    "bun test v1.3.4",
    "✓ opens a running command row",
    "✓ keeps the transcript anchor",
    "✓ reads a bounded output tail",
    "✓ exposes Open in terminal",
    "11 passed · 3 running",
    "watching for the next event…",
  ],
  complexity: [
    "$ bun run lint:complexity",
    "Web complexity candidate",
    "✗ BackgroundActivityGallery has complexity 21 (max 20)",
    "  at conversation/BackgroundActivity.gallery.tsx:214:1",
    "1 error · 0 warnings",
    "process exited with code 1",
    "tail closed · exit 1",
    "failure remains available for review",
  ],
};

const DONE_AGENTS = [
  "Read the daemon update docs",
  "Trace the process registry",
  "Review the gallery capture matrix",
  "Check the dark-theme contrast",
];

function commandLabel(command: Command) {
  return command.state === "failed" ? "Failed" : "Running";
}

function CommandTail({ item, initialOpen = false }: { item: Command; initialOpen?: boolean }) {
  const [open, setOpen] = useState(initialOpen);
  const [revision, setRevision] = useState(0);
  const [lines, setLines] = useState(() => COMMAND_OUTPUTS[item.id] ?? []);
  const [terminalOpened, setTerminalOpened] = useState(false);
  const activity = useContext(ActivityStateContext);
  const stopped = activity.stopped.has(item.id);
  const tailRef = useRef<HTMLPreElement>(null);
  useEffect(() => {
    if (open && tailRef.current) tailRef.current.scrollTop = tailRef.current.scrollHeight;
  }, [open, revision]);
  const followTail = () => {
    if (stopped || item.state !== "running") return;
    setLines((current) => (current.length >= 10 ? current : [...current, `[tail ${revision + 1}] ${item.detail}`]));
    setRevision((value) => value + 1);
  };
  return (
    <details
      className="bg-gallery__command"
      data-command-state={stopped ? "stopped" : item.state}
      open={open}
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>
        <span className="bg-gallery__status-dot" aria-hidden="true" />
        <span className="bg-gallery__command-copy">
          <code>{item.command}</code>
          <small>{item.detail}</small>
        </span>
        <span className="bg-gallery__command-state">{stopped ? "Stopped" : commandLabel(item)}</span>
      </summary>
      <pre ref={tailRef} className="bg-gallery__tail-body" aria-label={`${item.command} live output`}>
        {lines.join("\n")}
      </pre>
      <div className="bg-gallery__tail-foot">
        <span className="bg-gallery__follow-dot" aria-hidden="true" />
        <span aria-live="polite">
          {stopped ? "Stopped · output held" : `Auto-scroll on · ${lines.length}-line tail`}
        </span>
        {item.state === "running" && (
          <button type="button" className="bg-gallery__text-button" onClick={followTail} disabled={stopped}>
            Follow tail
          </button>
        )}
        {item.state === "running" && (
          <button
            type="button"
            className="bg-gallery__text-button"
            onClick={() => activity.stop(item.id)}
            disabled={stopped}
            aria-label={`Stop ${item.command}`}
          >
            {stopped ? "Stopped" : "Stop"}
          </button>
        )}
        <button
          type="button"
          className="bg-gallery__terminal-button"
          onClick={() => setTerminalOpened(true)}
          aria-label={terminalOpened ? `${item.command} terminal opened` : `Open ${item.command} in terminal`}
        >
          <span aria-live="polite">{terminalOpened ? "Terminal opened" : "Open in terminal"}</span>
        </button>
      </div>
    </details>
  );
}

function CommandRows({ compact = false, initialOpenId }: { compact?: boolean; initialOpenId?: string }) {
  return (
    <div className={`bg-gallery__commands${compact ? " bg-gallery__commands--compact" : ""}`}>
      {COMMANDS.map((item) => (
        <CommandTail key={item.id} item={item} initialOpen={item.id === initialOpenId} />
      ))}
    </div>
  );
}

function DoneSummary({ compact = false }: { compact?: boolean }) {
  return (
    <div className={`bg-gallery__done${compact ? " bg-gallery__done--compact" : ""}`} data-done-count="101">
      <span className="bg-gallery__done-mark" aria-hidden="true">
        ✓
      </span>
      <span>
        <strong>101 subagents done</strong>
        {!compact && <small>All completed work is available from the activity surface.</small>}
      </span>
    </div>
  );
}

function ActivityHeader({ placement }: { placement: string }) {
  const { stopped } = useContext(ActivityStateContext);
  const running = COMMANDS.filter((item) => item.state === "running" && !stopped.has(item.id)).length;
  const stoppedCount = COMMANDS.filter((item) => item.state === "running" && stopped.has(item.id)).length;
  return (
    <header className="bg-gallery__header">
      <div>
        <span className="bg-gallery__eyebrow">Background activity</span>
        <h2>{placement}</h2>
      </div>
      <span className="bg-gallery__count-badge">
        {running} running{stoppedCount ? ` · ${stoppedCount} stopped` : ""}
      </span>
    </header>
  );
}

function Composer() {
  return (
    <div className="bg-gallery__composer" data-composer>
      <span>Ask the agent to keep going…</span>
      <button type="button" aria-label="Send prompt">
        ↑
      </button>
    </div>
  );
}

function CompactPill({ onExpand }: { onExpand: () => void }) {
  return (
    <button type="button" className="bg-gallery__pill" data-activity-pill onClick={onExpand}>
      <span className="bg-gallery__pill-dots" aria-hidden="true">
        <i />
        <i />
        <i className="is-failed" />
      </span>
      <strong>Background activity</strong>
      <span>2 running · 1 failed · 101 done</span>
      <span className="bg-gallery__pill-chevron" aria-hidden="true">
        ⌄
      </span>
    </button>
  );
}

function DoneList() {
  return (
    <div className="bg-gallery__done-list">
      {DONE_AGENTS.map((name) => (
        <div className="bg-gallery__done-agent" key={name}>
          <span className="bg-gallery__done-agent-mark" aria-hidden="true">
            ✓
          </span>
          <span>{name}</span>
          <small>done</small>
        </div>
      ))}
      <span className="bg-gallery__done-more">+97 more completed agents</span>
    </div>
  );
}

function PinnedSurface() {
  return (
    <div className="bg-gallery__surface bg-gallery__surface--pinned" data-surface="pinned-live-tail">
      <ActivityHeader placement="Pinned above transcript" />
      <p className="bg-gallery__intro">Keep long-running work visible while the conversation continues.</p>
      <CommandRows compact initialOpenId="dev-server" />
      <DoneSummary compact />
    </div>
  );
}

function TranscriptSurface() {
  return (
    <div className="bg-gallery__surface bg-gallery__surface--transcript" data-surface="after-latest-message">
      <ActivityHeader placement="After latest message" />
      <div className="bg-gallery__message bg-gallery__message--user">
        Can you run the webview checks and report the failures?
      </div>
      <div className="bg-gallery__message bg-gallery__message--agent">
        I started the checks. I’ll keep the output here while the next files finish.
      </div>
      <div className="bg-gallery__latest-label">Latest message · activity follows</div>
      <CommandRows compact initialOpenId="dev-server" />
      <DoneSummary compact />
    </div>
  );
}

function CompactSurface() {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className="bg-gallery__shell bg-gallery__shell--compact" data-surface="compact-pill">
      <div className="bg-gallery__transcript-copy">
        <span className="bg-gallery__eyebrow">Agent chat</span>
        <p>Two checks are still running. The completed subagents stay quiet until you need their detail.</p>
      </div>
      {expanded ? (
        <div className="bg-gallery__expanded-from-pill" data-expanded-from-pill>
          <ActivityHeader placement="Expanded activity" />
          <CommandRows compact initialOpenId="dev-server" />
          <DoneSummary compact />
        </div>
      ) : (
        <CompactPill onExpand={() => setExpanded(true)} />
      )}
      <Composer />
    </div>
  );
}

function SidePanelSurface() {
  return (
    <div className="bg-gallery__shell bg-gallery__shell--side" data-surface="side-panel">
      <main className="bg-gallery__transcript-copy">
        <span className="bg-gallery__eyebrow">Agent chat · side panel open</span>
        <h2>Review the webview background checks</h2>
        <p>The agent is still working. The side panel keeps commands and subagents one click away.</p>
        <div className="bg-gallery__message bg-gallery__message--agent">
          I found one complexity failure and two live commands.
        </div>
        <Composer />
      </main>
      <aside className="bg-gallery__side-panel" aria-label="Background activity">
        <ActivityHeader placement="Activity" />
        <div className="bg-gallery__side-section">
          <span className="bg-gallery__eyebrow">Commands</span>
          <CommandRows />
        </div>
        <div className="bg-gallery__side-section">
          <span className="bg-gallery__eyebrow">Subagents</span>
          <DoneSummary />
          <DoneList />
        </div>
      </aside>
    </div>
  );
}

// The production tray, with both Stop implementations and an untimed, non-opening row.
// Synthetic names only; no process or session request leaves this fixture.
const DURATION_ITEMS: TrayItem[] = [
  ...[9, 59].map((seconds, index): TrayItem => ({
    kind: "agent",
    id: `duration-agent-${index}`,
    depth: index === 1 ? 1 : 0,
    agent: {
      id: `duration-agent-${index}`,
      parent: null,
      name: ["Quick check", "Nested check", "Integration review"][index]!,
      state: "running",
      startedAt: GALLERY_NOW - seconds * 1000,
    },
  })),
  {
    kind: "session",
    id: "untimed-session",
    session: { sessionId: "untimed-session", title: "Waiting review", state: "waiting" },
  },
  ...[1879, 46799].map((seconds, index): TrayItem => ({
    kind: "command",
    id: `duration-command-${index}`,
    command: {
      id: `duration-command-${index}`,
      processId: `duration-process-${index}`,
      command: index === 0 ? "bun run check" : "bun run overnight",
      state: "running",
      startedAt: GALLERY_NOW - seconds * 1000,
    },
  })),
  {
    kind: "agent",
    id: "duration-agent-long",
    depth: 0,
    agent: {
      id: "duration-agent-long",
      parent: null,
      name: "Integration review",
      state: "running",
      startedAt: GALLERY_NOW - 8399 * 1000,
    },
  },
];

function DurationTray() {
  return (
    <div className="acpmux-shell" data-bg-gallery style={{ padding: "8px", flexDirection: "column" }}>
      <SubagentTray
        items={DURATION_ITEMS}
        working
        waiting={new Set()}
        onOpen={() => {}}
        onOpenCommand={() => {}}
        stop={async () => undefined}
        stopProcess={async () => undefined}
      />
    </div>
  );
}

function BackgroundActivityGallery({ surface, mode }: Props) {
  const [stopped, setStopped] = useState<Set<string>>(() => new Set());
  if (surface === "duration-columns") return <DurationTray />;
  const activity: ActivityState = { stopped, stop: (id) => setStopped((current) => new Set(current).add(id)) };
  return (
    <ActivityStateContext.Provider value={activity}>
      <div className="bg-gallery" data-bg-gallery data-mode={mode} data-surface={surface}>
        {surface === "pinned-live-tail" && <PinnedSurface />}
        {surface === "after-latest-message" && <TranscriptSurface />}
        {surface === "compact-pill" && <CompactSurface />}
        {surface === "side-panel" && <SidePanelSurface />}
      </div>
    </ActivityStateContext.Provider>
  );
}

const paired = (surface: Surface, note: string): Record<string, ComponentVariant<Props>> => ({
  [`${surface}-light`]: {
    note: `${note} Light theme uses the host's readable status colors and raised surfaces.`,
    props: { surface, mode: "light" },
  },
  [`${surface}-dark`]: {
    note: `${note} Dark theme keeps the same hierarchy with quiet separators and a bright live tail.`,
    props: { surface, mode: "dark" },
  },
});

export default componentEntry<Props>({
  id: "agent-pane.background-activity",
  title: "Background activity placements",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 760,
  widths: { narrow: 420, normal: 760, wide: 1040 },
  anchors: [{ selector: "[data-bg-gallery]" }],
  covers: ["agent-session/acpmux/conversation/BackgroundTaskNote.tsx#BackgroundTaskNote"],
  styles: () =>
    Promise.all([
      import("./BackgroundActivity.gallery.css"),
      import("../styles.css"),
      import("./conversation.css"),
      import("../summary/summary.css"),
      import("../session-info/sessionInfo.css"),
      import("../subagents/subagents.css"),
    ]),
  load: async () => BackgroundActivityGallery,
  variants: {
    "duration-columns": {
      note: "Production tray with 9s through 12h 59m 59s, nested agents, commands and an empty stop/time slot. The header shows only the longest-running active item's time.",
      props: { surface: "duration-columns", mode: "dark" },
    },
    ...paired(
      "pinned-live-tail",
      "A pinned panel keeps two running commands, one failed command and 101 completed subagents visible; each command row expands its own ten-line live tail and offers Follow tail, Stop and Open in terminal.",
    ),
    ...paired(
      "after-latest-message",
      "The same activity surface follows the latest assistant message, so the transcript still reads naturally while the output remains expandable.",
    ),
    ...paired(
      "compact-pill",
      "A compact pill sits immediately above the composer and expands into the same activity surface without replacing the transcript.",
    ),
    ...paired(
      "side-panel",
      "A side panel lists all three commands and the 101-agent completion summary beside the conversation.",
    ),
  },
});
