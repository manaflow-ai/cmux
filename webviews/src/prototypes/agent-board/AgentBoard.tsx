// l10n-allow-file: isolated gallery prototype, not shipped UI.
// Agent Board (prototype): every agent's work-tracking ledger in one place, off until the person
// turns it on. Three directions for the agent detail sit behind the prototype picker.
import { useEffect, useRef, useState } from "react";
import { AGENTS, AGENTS_STRESS, AGENTS_WITH_ERROR, type AgentFixture } from "./fixtures";
import { coverage, foldLedger, type Board, type EvidenceRecord } from "./ledger";
import { Onboarding } from "./Onboarding";
import { EvidenceViewer } from "./parts";
import { LedgerView, MatrixView, StoryView } from "./views";

export const DESIGNS = ["ledger", "matrix", "story"] as const;
export type Design = (typeof DESIGNS)[number];
const DESIGN_LABEL: Record<Design, string> = { ledger: "Ledger", matrix: "Matrix", story: "Story" };

export type BoardState = "off" | "confirm" | "on-empty" | "loading" | "live" | "error" | "stress";

export type AgentBoardProps = {
  design?: Design;
  state?: BoardState;
  platform?: "mac" | "iphone";
  needsYou?: boolean;
  /** Hide the picker (captures of one direction). */
  picker?: boolean;
};

function Picker({ current, onChange, onReplay }: { current: Design; onChange(d: Design): void; onReplay(): void }) {
  const nav = useRef<HTMLElement>(null);
  const highlight = useRef<HTMLSpanElement>(null);
  const items = useRef<Array<HTMLButtonElement | null>>([]);
  useEffect(() => {
    const move = () => {
      const item = items.current[DESIGNS.indexOf(current)];
      if (item && highlight.current) {
        highlight.current.style.width = item.offsetWidth + "px";
        highlight.current.style.transform = "translateX(" + item.offsetLeft + "px)";
      }
    };
    move();
    let second: number | undefined;
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(() => nav.current?.setAttribute("data-ready", ""));
    });
    window.addEventListener("resize", move);
    return () => {
      cancelAnimationFrame(first);
      if (second !== undefined) cancelAnimationFrame(second);
      window.removeEventListener("resize", move);
    };
  }, [current]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (
        event.defaultPrevented ||
        !target ||
        /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) ||
        target.isContentEditable ||
        target.closest("[role=dialog]") ||
        event.metaKey ||
        event.ctrlKey ||
        event.altKey
      )
        return;
      const index = DESIGNS.indexOf(current);
      const number = Number(event.key);
      if (number >= 1 && number <= DESIGNS.length) onChange(DESIGNS[number - 1]!);
      else if (event.key === "ArrowRight") onChange(DESIGNS[(index + 1) % DESIGNS.length]!);
      else if (event.key === "ArrowLeft") onChange(DESIGNS[(index + DESIGNS.length - 1) % DESIGNS.length]!);
      else if (event.key.toLowerCase() === "r") onReplay();
      else return;
      event.preventDefault();
    };
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  }, [current, onChange, onReplay]);
  return (
    <nav ref={nav} className="proto-picker" aria-label="Prototype variants">
      <span ref={highlight} className="proto-picker-highlight" aria-hidden="true" />
      {DESIGNS.map((name, index) => (
        <button
          key={name}
          ref={(element) => {
            items.current[index] = element;
          }}
          type="button"
          className="proto-picker-item"
          data-active={current === name ? "" : undefined}
          aria-current={current === name ? "true" : undefined}
          onClick={() => onChange(name)}
        >
          {DESIGN_LABEL[name]}
        </button>
      ))}
    </nav>
  );
}

type Loaded = { agent: AgentFixture; board: Board };

function agentsFor(state: BoardState): AgentFixture[] {
  if (state === "error") return AGENTS_WITH_ERROR;
  if (state === "stress") return AGENTS_STRESS;
  return AGENTS;
}

function AgentList({ loaded, selected, onSelect }: { loaded: Loaded[]; selected: string; onSelect(id: string): void }) {
  return (
    <nav className="ab-agents" aria-label="Agents">
      {loaded.map(({ agent, board }) => {
        const c = coverage(board.permutations);
        const human = board.decisions.filter((d) => d.needsHuman).length;
        const broken = c.broken + board.problems.length;
        return (
          <button
            type="button"
            key={agent.id}
            className="ab-agent"
            aria-current={agent.id === selected ? "true" : undefined}
            onClick={() => onSelect(agent.id)}
          >
            <span
              className={`ab-dot${agent.live ? " ab-dot-live" : ""}`}
              aria-label={agent.live ? "Working" : "Idle"}
            />
            <span className="ab-agent-text">
              <span className="ab-agent-name">{board.task?.title ?? agent.name}</span>
              <span className="ab-agent-meta">
                {agent.harness} · {agent.workspace} · {agent.updated}
              </span>
            </span>
            <span className="ab-agent-counts">
              {human > 0 && <span className="ab-flag">{human}</span>}
              {broken > 0 && <span className="ab-count-bad">{broken}</span>}
              <span className="ab-muted">
                {c.verified}/{c.total}
              </span>
            </span>
          </button>
        );
      })}
    </nav>
  );
}

function BoardHeader({
  loaded,
  needsYou,
  onNeedsYou,
}: {
  loaded: Loaded[];
  needsYou: boolean;
  onNeedsYou(v: boolean): void;
}) {
  const caps = loaded.reduce((n, l) => n + l.board.capabilities.length, 0);
  const human = loaded.reduce((n, l) => n + l.board.decisions.filter((d) => d.needsHuman).length, 0);
  const all = coverage(loaded.flatMap((l) => l.board.permutations));
  return (
    <header className="ab-header">
      <div>
        <h1>Agent Board</h1>
        <p className="ab-muted">
          {loaded.length} agents · {caps} capabilities · {all.verified} of {all.total} states verified
        </p>
      </div>
      <label className="ab-toggle">
        <input
          type="checkbox"
          aria-label="Needs you"
          checked={needsYou}
          onChange={(e) => onNeedsYou(e.target.checked)}
        />
        Needs you{human ? ` (${human})` : ""}
      </label>
    </header>
  );
}

function Detail({ loaded, design, needsYou }: { loaded: Loaded; design: Design; needsYou: boolean }) {
  const [viewing, setViewing] = useState<EvidenceRecord | null>(null);
  const { board, agent } = loaded;
  const View = design === "matrix" ? MatrixView : design === "story" ? StoryView : LedgerView;
  return (
    <section className="ab-detail" aria-label={board.task?.title ?? agent.name}>
      <header className="ab-detail-head">
        <h2>{board.task?.title ?? agent.name}</h2>
        {board.task?.goal && <p className="ab-goal">{board.task.goal}</p>}
        <p className="ab-detail-links">
          {board.task?.branch && <code>{board.task.branch}</code>}
          {board.task?.pr && (
            <a href={board.task.pr} target="_blank" rel="noreferrer">
              Pull request
            </a>
          )}
        </p>
      </header>
      {board.problems.length > 0 && (
        <div className="ab-problems" role="alert">
          <strong>
            {board.problems.length} ledger line{board.problems.length > 1 ? "s" : ""} could not be read
          </strong>
          <ul>
            {board.problems.map((p) => (
              <li key={p.line}>
                Line {p.line}: {p.reason} <code className="ab-break">{p.text}</code>
              </li>
            ))}
          </ul>
        </div>
      )}
      {board.capabilities.length === 0 && board.decisions.length === 0 ? (
        <p className="ab-muted">This agent has not recorded anything yet.</p>
      ) : (
        <View key={`${agent.id}:${design}:${needsYou}`} board={board} needsYou={needsYou} onOpen={setViewing} />
      )}
      <EvidenceViewer board={board} evidence={viewing} onClose={() => setViewing(null)} />
    </section>
  );
}

function Loading() {
  return (
    <div className="ab-board" aria-busy="true" aria-label="Loading ledgers">
      <div className="ab-agents">
        {[0, 1, 2, 3].map((i) => (
          <span key={i} className="ab-skeleton ab-skeleton-row" />
        ))}
      </div>
      <div className="ab-detail">
        <span className="ab-skeleton ab-skeleton-title" />
        <span className="ab-skeleton ab-skeleton-block" />
        <span className="ab-skeleton ab-skeleton-block" />
      </div>
    </div>
  );
}

export function AgentBoard({
  design = "ledger",
  state = "live",
  platform = "mac",
  needsYou: needsYouProp = false,
  picker = true,
}: AgentBoardProps) {
  const [current, setCurrent] = useState<Design>(() => {
    const fromUrl = Number(new URLSearchParams(location.search).get("v"));
    return DESIGNS[fromUrl - 1] ?? design;
  });
  const [mode, setMode] = useState<BoardState>(state);
  const [replay, setReplay] = useState(0);
  const [needsYou, setNeedsYou] = useState(needsYouProp);
  const [loaded] = useState<Loaded[]>(() =>
    agentsFor(state).map((agent) => ({ agent, board: foldLedger(agent.ledger) })),
  );
  const [selected, setSelected] = useState(loaded[0]?.agent.id ?? "");
  const switchDesign = (next: Design) => {
    setCurrent(next);
    const url = new URL(location.href);
    url.searchParams.set("v", String(DESIGNS.indexOf(next) + 1));
    history.replaceState(null, "", url);
  };
  const active = loaded.find((l) => l.agent.id === selected) ?? loaded[0];
  const showsBoard = mode === "live" || mode === "error" || mode === "stress";
  return (
    <div className={`ab-root ab-${platform}`} data-state={mode}>
      {mode === "off" || mode === "confirm" ? (
        <Onboarding confirming={mode === "confirm"} onConfirm={() => setMode("on-empty")} />
      ) : mode === "on-empty" ? (
        <section className="ab-empty" aria-labelledby="ab-empty-title">
          <p className="ab-eyebrow">Agent Board · On</p>
          <h1 id="ab-empty-title">Waiting for the first ledger</h1>
          <p className="ab-lede">
            Agent sessions you start from now on keep a ledger. Their work shows here as they finish each step. Sessions
            that were already running are not tracked.
          </p>
          <ol className="ab-steps">
            <li>Start an agent in any workspace.</li>
            <li>It records each capability, decision and state, with evidence.</li>
            <li>Review it here; filter to what needs you.</li>
          </ol>
          <button type="button" className="ab-secondary" onClick={() => setMode("off")}>
            Turn Off
          </button>
        </section>
      ) : mode === "loading" ? (
        <Loading />
      ) : (
        showsBoard &&
        active && (
          <>
            <BoardHeader loaded={loaded} needsYou={needsYou} onNeedsYou={setNeedsYou} />
            <div className="ab-board" key={replay}>
              <AgentList loaded={loaded} selected={active.agent.id} onSelect={setSelected} />
              <Detail loaded={active} design={current} needsYou={needsYou} />
            </div>
          </>
        )
      )}
      {picker && showsBoard && (
        <Picker current={current} onChange={switchDesign} onReplay={() => setReplay((n) => n + 1)} />
      )}
    </div>
  );
}
