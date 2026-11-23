// l10n-allow-file: gallery design fixtures for AUTO computers (cmuxterm-hq RFD 0080), not shipped UI.
// The Where button is RFD 0078's (Hybrid, Only in Cloud, Only on This Mac; Keep running), drawn here
// unchanged and never showing a size. its one line (cmux#52291 `where`) names the place, and RFD 0080's status replaces it while something happens;
// and Size, Sleep and Why rows under RFD 0078's rows in its popover. Pure presentation over a typed
// state; where and how big are decided in Rust (acpmux placement and the server's AutoSize), never here.

/// Where the agent's computer is and what it is doing.
export type AutoComputerState =
  | { kind: "local" }
  | { kind: "cloud-awake"; vcpu: number; gb: number }
  | { kind: "cloud-sleeping" }
  | { kind: "preparing"; seconds: number }
  | { kind: "moving"; to: "Cloud" | "This Mac"; seconds: number }
  | { kind: "move-failed"; reason: string }
  | { kind: "spend-paused" }
  | { kind: "pinned"; vcpu: number; gb: number };

/// `button`: the composer with RFD 0078's button and the status line. `popover`: the button opened.
/// `create`: the new-agent card, which asks for a task and a project and nothing about machines.
export type AutoComputerSurface = "button" | "popover" | "create";

/// RFD 0078's three states (wire `auto`, `cloud`, `local`).
export type AutoComputerMode = "hybrid" | "cloud" | "mac";

export type AutoComputerDesignsProps = {
  surface: AutoComputerSurface;
  state: AutoComputerState;
  mode?: AutoComputerMode;
  keepRunning?: boolean;
};

type Tone = "ok" | "busy" | "idle" | "warn";

const MODE_LABEL: Record<AutoComputerMode, string> = {
  hybrid: "Hybrid",
  cloud: "Only in Cloud",
  mac: "Only on This Mac",
};

function place(state: AutoComputerState): string {
  switch (state.kind) {
    case "local":
    case "move-failed":
      return "This Mac";
    case "moving":
      return state.to === "Cloud" ? "This Mac" : "Cloud";
    default:
      return "Cloud";
  }
}

/// The status line beside the button: empty while the chat simply runs where it is.
function status(state: AutoComputerState): { text: string; tone: Tone; action: string | null } | null {
  switch (state.kind) {
    case "local":
    case "cloud-awake":
    case "pinned":
      return null;
    case "cloud-sleeping":
      return { text: "Sleeping", tone: "idle", action: null };
    case "preparing":
      return { text: `Preparing cloud computer… ${state.seconds} s`, tone: "busy", action: null };
    case "moving":
      return { text: `Moving to ${state.to}… ${state.seconds} s`, tone: "busy", action: "Cancel" };
    case "move-failed":
      return { text: "Move didn't finish", tone: "warn", action: "Retry" };
    case "spend-paused":
      return { text: "Paused at your overage limit", tone: "warn", action: "Raise limit" };
  }
}

function why(state: AutoComputerState): string {
  switch (state.kind) {
    case "local":
      return "On your Mac: it has room, so this uses none of your Cloud time.";
    case "cloud-awake":
      return "Moved to Cloud at 14:02: your Mac was under memory pressure. Grew to 4 vCPU when vitest needed it.";
    case "cloud-sleeping":
      return "Sleeping while it waits on you. Its memory and running processes are kept.";
    case "preparing":
      return "Your Mac is on battery, so Cloud is getting a computer ready. The agent is already answering.";
    case "moving":
      return "Moving at a tool boundary. The chat, its queue and open questions move with it.";
    case "move-failed":
      return `${state.reason} Still on This Mac; nothing was lost. Auto won't try again for 10 minutes.`;
    case "spend-paused":
      return "Paused, not stopped: memory and processes are kept. Agents on your Mac keep running.";
    case "pinned":
      return "You pinned this agent's size. Auto still chooses where it runs and when it sleeps.";
  }
}

/// RFD 0078's button with its one line beside the name (cmux#52291's `where` slot): at rest it names the
/// place; while something is happening RFD 0080's status replaces it, so there is never both.
function WhereButton({
  state,
  mode,
  keepRunning,
}: {
  state: AutoComputerState;
  mode: AutoComputerMode;
  keepRunning: boolean;
}) {
  const line = status(state);
  return (
    <span className="auto-computer-chip" data-lit={keepRunning || undefined} data-tone={line?.tone}>
      <span className="auto-computer-dot" aria-hidden />
      <span className="auto-computer-label">{keepRunning ? "Keep running" : MODE_LABEL[mode]}</span>
      <span className="auto-computer-where">· {line ? line.text : place(state)}</span>
      {line?.action && (
        <button type="button" className="auto-computer-action">
          {line.action}
        </button>
      )}
      <span className="auto-computer-caret" aria-hidden>
        ▾
      </span>
    </span>
  );
}

function Segmented({ name, options, picked }: { name: string; options: string[]; picked: string }) {
  return (
    <div className="auto-computer-row">
      {name && <span className="auto-computer-row-name">{name}</span>}
      <span className="auto-computer-segments">
        {options.map((option) => (
          <span key={option} className="auto-computer-segment" data-picked={option === picked || undefined}>
            {option}
          </span>
        ))}
      </span>
    </div>
  );
}

function Popover({
  state,
  mode,
  keepRunning,
}: {
  state: AutoComputerState;
  mode: AutoComputerMode;
  keepRunning: boolean;
}) {
  const pinned = state.kind === "pinned";
  const size =
    state.kind === "cloud-awake" || state.kind === "pinned"
      ? `now ${state.vcpu} vCPU · ${state.gb} GB${pinned ? " · pinned" : ", grows as it works"}`
      : state.kind === "local"
        ? "uses your Mac"
        : "starts at 2 vCPU · 4 GB, grows as it works";
  return (
    <div className="auto-computer-popover" role="dialog" aria-label="Where this chat runs">
      <div className="auto-computer-title">Computer for “fix-login-redirect”</div>
      <Segmented name="" options={Object.values(MODE_LABEL)} picked={MODE_LABEL[mode]} />
      <div className="auto-computer-row">
        <span className="auto-computer-toggle" data-on={keepRunning || undefined} aria-hidden />
        <span>Keep running</span>
      </div>
      <div className="auto-computer-hint-flat">41 of 100 hours used this week</div>
      <div className="auto-computer-divider" />
      <Segmented name="Size" options={["Auto", "Pin…"]} picked={pinned ? "Pin…" : "Auto"} />
      <div className="auto-computer-hint">{size}</div>
      <Segmented name="Sleep" options={["Auto", "Keep awake 1 h", "4 h"]} picked="Auto" />
      <div className="auto-computer-hint">Sleeps while it waits on the model or on you.</div>
      <div className="auto-computer-row auto-computer-why-row">
        <span className="auto-computer-row-name">Why</span>
        <span className="auto-computer-why">{why(state)}</span>
      </div>
      <div className="auto-computer-buttons">
        <button type="button">Open terminal</button>
        <button type="button">Computer details</button>
      </div>
    </div>
  );
}

function ControlRow({
  state,
  mode,
  keepRunning,
}: {
  state: AutoComputerState;
  mode: AutoComputerMode;
  keepRunning: boolean;
}) {
  return (
    <>
      <WhereButton state={state} mode={mode} keepRunning={keepRunning} />
    </>
  );
}

export function AutoComputerDesigns({
  surface,
  state,
  mode = "hybrid",
  keepRunning = false,
}: AutoComputerDesignsProps) {
  return (
    <div className="auto-computer-stage" data-surface={surface} data-place={place(state)}>
      <style>{STYLES}</style>
      {surface === "create" ? (
        <div className="auto-computer-create">
          <div className="auto-computer-title">What should the agent do?</div>
          <div className="auto-computer-input">Fix the login redirect loop on Safari</div>
          <div className="auto-computer-create-row">
            <span className="auto-computer-picker">Project: cmux</span>
            <span className="auto-computer-picker">Agent: Claude</span>
            <span className="auto-computer-spacer" />
            <ControlRow state={state} mode={mode} keepRunning={keepRunning} />
            <button type="button" className="auto-computer-start">
              Start
            </button>
          </div>
        </div>
      ) : (
        <div className="auto-computer-composer">
          <span className="auto-computer-placeholder">Ask anything…</span>
          <div className="auto-computer-create-row">
            <span className="auto-computer-picker">Claude</span>
            <span className="auto-computer-spacer" />
            <ControlRow state={state} mode={mode} keepRunning={keepRunning} />
          </div>
          {surface === "popover" && <Popover state={state} mode={mode} keepRunning={keepRunning} />}
        </div>
      )}
    </div>
  );
}

const STYLES = `
.auto-computer-stage{display:flex;flex-direction:column;justify-content:flex-end;height:100%;padding:16px 24px;box-sizing:border-box;color:var(--agent-text);font-size:var(--text-body)}
.auto-computer-composer,.auto-computer-create{position:relative;display:flex;flex-direction:column;gap:8px;padding:10px 12px;border-radius:14px;background:var(--agent-input-bg)}
.auto-computer-placeholder{color:var(--acpmux-composer-placeholder)}
.auto-computer-create-row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.auto-computer-spacer{flex:1}
.auto-computer-picker{color:var(--agent-muted);font-size:var(--text-detail)}
.auto-computer-chip{display:inline-flex;align-items:center;gap:6px;padding:2px 8px;border-radius:999px;border:1px solid var(--agent-border,rgba(127,127,127,.3));font-size:var(--text-detail)}
.auto-computer-dot{width:7px;height:7px;border-radius:50%;background:var(--agent-success,#30a46c)}
.auto-computer-chip[data-lit]{border-color:var(--agent-accent,#0a84ff);box-shadow:0 0 0 2px color-mix(in srgb,var(--agent-accent,#0a84ff) 25%,transparent)}
.auto-computer-label{font-weight:600}
.auto-computer-caret{color:var(--agent-muted);font-size:10px}
.auto-computer-where{color:var(--agent-muted)}
.auto-computer-chip[data-tone=busy] .auto-computer-dot{background:var(--agent-accent,#0a84ff)}
.auto-computer-chip[data-tone=warn] .auto-computer-dot{background:var(--agent-warning,#f5a623)}
.auto-computer-chip[data-tone=idle] .auto-computer-dot{background:transparent;border:1px solid var(--agent-muted)}
.auto-computer-action{border:0;background:none;padding:0;color:var(--agent-accent,#0a84ff);font:inherit;cursor:pointer}
.auto-computer-toggle{width:26px;height:14px;border-radius:7px;background:var(--agent-input-bg);border:1px solid var(--agent-border,rgba(127,127,127,.3))}
.auto-computer-toggle[data-on]{background:var(--agent-accent,#0a84ff)}
.auto-computer-divider{height:1px;background:var(--agent-border,rgba(127,127,127,.3))}
.auto-computer-hint-flat{color:var(--agent-muted);font-size:var(--text-detail)}
.auto-computer-why-row{align-items:flex-start}
.auto-computer-popover{position:absolute;right:8px;bottom:calc(100% + 8px);width:min(380px,calc(100% - 16px));display:flex;flex-direction:column;gap:8px;padding:12px;border-radius:12px;background:var(--agent-menu-bg,var(--agent-input-bg));box-shadow:0 8px 24px rgba(0,0,0,.25)}
.auto-computer-title{font-weight:600}
.auto-computer-row{display:flex;align-items:center;gap:8px}
.auto-computer-row-name{width:48px;color:var(--agent-muted);font-size:var(--text-detail)}
.auto-computer-segments{display:inline-flex;gap:2px;padding:2px;border-radius:8px;background:var(--agent-input-bg)}
.auto-computer-segment{padding:2px 8px;border-radius:6px;font-size:var(--text-detail)}
.auto-computer-segment[data-picked]{background:var(--agent-menu-selected,rgba(127,127,127,.25));font-weight:600}
.auto-computer-hint{margin-left:56px;color:var(--agent-muted);font-size:var(--text-detail)}
.auto-computer-why{margin:0;color:var(--agent-muted);font-size:var(--text-detail)}
.auto-computer-buttons{display:flex;gap:8px;flex-wrap:wrap}
.auto-computer-buttons button,.auto-computer-start{font:inherit;font-size:var(--text-detail);padding:3px 10px;border-radius:7px;border:1px solid var(--agent-border,rgba(127,127,127,.3));background:none;color:inherit}
.auto-computer-input{padding:6px 0}
`;
