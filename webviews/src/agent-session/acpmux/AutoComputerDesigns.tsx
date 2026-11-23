// l10n-allow-file: gallery design fixtures for the AUTO computer chip (cmuxterm-hq RFD 0078), not shipped UI.
// An agent has a computer, not the other way round: the composer shows one chip that says where the
// agent runs, how big its computer is, whether it is awake and why, and opens to pin any of them.
// Pure presentation over a typed state; where and how big are decided in Rust (acpmux placement and
// the server's AutoSize), never here. Nothing in the app renders this yet.

/// Where the agent's computer is and what it is doing.
export type AutoComputerState =
  | { kind: "local" }
  | { kind: "cloud-awake"; vcpu: number; gb: number }
  | { kind: "cloud-sleeping" }
  | { kind: "preparing"; seconds: number }
  | { kind: "moving"; to: "Cloud" | "This Mac"; seconds: number }
  | { kind: "move-failed"; reason: string }
  | { kind: "spend-paused"; limit: string }
  | { kind: "pinned"; vcpu: number; gb: number };

/// `chip`: the closed chip in the composer. `popover`: the chip opened. `create`: the new-agent card,
/// which asks for a task and a project and nothing about machines.
export type AutoComputerSurface = "chip" | "popover" | "create";

/// `prefix`: "Auto · Cloud". `suffix`: "Cloud (auto)". The RFD's open taste question, shown both ways.
export type AutoComputerWording = "prefix" | "suffix";

export type AutoComputerDesignsProps = {
  surface: AutoComputerSurface;
  state: AutoComputerState;
  wording?: AutoComputerWording;
};

type Tone = "ok" | "busy" | "idle" | "warn";

function place(state: AutoComputerState): string {
  switch (state.kind) {
    case "local":
      return "This Mac";
    case "cloud-awake":
    case "cloud-sleeping":
    case "preparing":
    case "spend-paused":
    case "pinned":
      return "Cloud";
    case "moving":
      return state.to === "Cloud" ? "This Mac" : "Cloud";
    case "move-failed":
      return "This Mac";
  }
}

function chipParts(state: AutoComputerState): { detail: string | null; tone: Tone; action: string | null } {
  switch (state.kind) {
    case "local":
      return { detail: "free", tone: "ok", action: null };
    case "cloud-awake":
      return { detail: `${state.vcpu} vCPU · ${state.gb} GB · awake`, tone: "ok", action: null };
    case "cloud-sleeping":
      return { detail: "sleeping", tone: "idle", action: null };
    case "preparing":
      return { detail: `preparing… ${state.seconds} s`, tone: "busy", action: null };
    case "moving":
      return { detail: `moving to ${state.to}… ${state.seconds} s`, tone: "busy", action: "Cancel" };
    case "move-failed":
      return { detail: "move didn't finish", tone: "warn", action: "Retry" };
    case "spend-paused":
      return { detail: `paused at your ${state.limit} limit`, tone: "warn", action: "Raise limit" };
    case "pinned":
      return { detail: `${state.vcpu} vCPU · ${state.gb} GB · pinned`, tone: "ok", action: null };
  }
}

function label(state: AutoComputerState, wording: AutoComputerWording): string {
  const where = place(state);
  if (state.kind === "pinned") return where;
  return wording === "prefix" ? `Auto · ${where}` : `${where} (auto)`;
}

function why(state: AutoComputerState): string {
  switch (state.kind) {
    case "local":
      return "Running on your Mac: it has room, so this costs nothing.";
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
      return "You pinned this agent's size and place. Auto leaves it alone until you unpin it.";
  }
}

function Chip({ state, wording }: { state: AutoComputerState; wording: AutoComputerWording }) {
  const parts = chipParts(state);
  return (
    <span className="auto-computer-chip" data-tone={parts.tone} data-pinned={state.kind === "pinned" || undefined}>
      <span className="auto-computer-dot" aria-hidden />
      <span className="auto-computer-label">{label(state, wording)}</span>
      {parts.detail && <span className="auto-computer-detail">{parts.detail}</span>}
      {parts.action && (
        <button type="button" className="auto-computer-action">
          {parts.action}
        </button>
      )}
    </span>
  );
}

function Segmented({ name, options, picked }: { name: string; options: string[]; picked: string }) {
  return (
    <div className="auto-computer-row">
      <span className="auto-computer-row-name">{name}</span>
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

function Popover({ state }: { state: AutoComputerState }) {
  const pinned = state.kind === "pinned";
  const size =
    state.kind === "cloud-awake" || state.kind === "pinned"
      ? `now ${state.vcpu} vCPU · ${state.gb} GB`
      : state.kind === "local"
        ? "uses your Mac"
        : "starts at 2 vCPU · 4 GB, grows as it works";
  return (
    <div className="auto-computer-popover" role="dialog" aria-label="Computer">
      <div className="auto-computer-title">Computer for “fix-login-redirect”</div>
      <Segmented
        name="Where"
        options={["Auto", "This Mac", "Cloud", "My machines"]}
        picked={pinned ? "Cloud" : "Auto"}
      />
      <Segmented name="Size" options={["Auto", "Pin…"]} picked={pinned ? "Pin…" : "Auto"} />
      <div className="auto-computer-hint">{size}</div>
      <Segmented name="Sleep" options={["Auto", "Keep awake 1 h", "4 h"]} picked="Auto" />
      <div className="auto-computer-hint">Sleeps while it waits on the model or on you.</div>
      <div className="auto-computer-row">
        <span className="auto-computer-row-name">Today</span>
        <span>
          {state.kind === "local" ? "on your Mac · free" : "38 min awake · about 3% of this month's allowance"}
        </span>
      </div>
      <p className="auto-computer-why">{why(state)}</p>
      <div className="auto-computer-buttons">
        <button type="button">{place(state) === "Cloud" ? "Move to This Mac" : "Move to Cloud"}</button>
        <button type="button">Open terminal</button>
        <button type="button">Details</button>
      </div>
    </div>
  );
}

function CreateCard({ state, wording }: { state: AutoComputerState; wording: AutoComputerWording }) {
  return (
    <div className="auto-computer-create">
      <div className="auto-computer-title">What should the agent do?</div>
      <div className="auto-computer-input">Fix the login redirect loop on Safari</div>
      <div className="auto-computer-create-row">
        <span className="auto-computer-picker">Project: cmux</span>
        <span className="auto-computer-picker">Agent: Claude</span>
        <span className="auto-computer-spacer" />
        <Chip state={state} wording={wording} />
        <button type="button" className="auto-computer-start">
          Start
        </button>
      </div>
    </div>
  );
}

export function AutoComputerDesigns({ surface, state, wording = "prefix" }: AutoComputerDesignsProps) {
  return (
    <div className="auto-computer-stage" data-surface={surface}>
      <style>{STYLES}</style>
      {surface === "create" ? (
        <CreateCard state={state} wording={wording} />
      ) : (
        <div className="auto-computer-composer">
          <span className="auto-computer-placeholder">Ask anything…</span>
          <div className="auto-computer-create-row">
            <span className="auto-computer-picker">Claude</span>
            <span className="auto-computer-spacer" />
            <Chip state={state} wording={wording} />
          </div>
          {surface === "popover" && <Popover state={state} />}
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
.auto-computer-dot{width:7px;height:7px;border-radius:50%;background:var(--agent-muted)}
.auto-computer-chip[data-tone=ok] .auto-computer-dot{background:var(--agent-success,#30a46c)}
.auto-computer-chip[data-tone=busy] .auto-computer-dot{background:var(--agent-accent,#0a84ff)}
.auto-computer-chip[data-tone=warn] .auto-computer-dot{background:var(--agent-warning,#f5a623)}
.auto-computer-chip[data-tone=idle] .auto-computer-dot{background:transparent;border:1px solid var(--agent-muted)}
.auto-computer-chip[data-pinned] .auto-computer-label::before{content:"Pinned · "}
.auto-computer-label{font-weight:600}
.auto-computer-detail{color:var(--agent-muted)}
.auto-computer-action{border:0;background:none;padding:0;color:var(--agent-accent,#0a84ff);font:inherit;cursor:pointer}
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
