// Pieces every view shares: the state mark, the "5 min" stamp, an agent's row, a pull request's
// chip and owner chips, and the view glyphs. Colors are theme roles only (pageBase.css,
// StatusGlyph's tints); nothing here is blue.
import type { ReactNode } from "react";
import { StatusGlyph } from "../../ui/StatusGlyph";
import type { StatusGlyphName } from "../../ui/statusGlyphs.generated";
import type { Strings } from "../shared/i18n";
import { agentPR, ciKind, folderName, LOCAL_MACHINE, shortDuration } from "./model";
import type { ChiefViewManifest, ChiefViewProps } from "./registry";
import type { AgentState, ChiefAgent } from "./types";

const GLYPH: Record<AgentState, StatusGlyphName> = {
  working: "working",
  waiting: "waiting",
  idle: "idle",
  failed: "error",
};

const NO_AGENTS: readonly ChiefAgent[] = [];

/** The agents a view shows: the read's, or one shared empty list so memos keep their inputs. */
export const agentsOf = (data: ChiefViewProps["data"]): readonly ChiefAgent[] =>
  data.agents.status === "ready" ? data.agents.reply : NO_AGENTS;

export const stateKey = (state: AgentState) => `chiefViews.state.${state}`;

export function StateMark({ state, strings }: { state: AgentState; strings: Strings }) {
  return <StatusGlyph name={GLYPH[state]} size={10} label={strings.t(stateKey(state))} className="cv-state" />;
}

/** "4 min" since `at`, in the page's language; nothing without a time. */
export function Ago({ at, now, strings }: { at?: number | null; now: number; strings: Strings }) {
  if (!at) return null;
  return (
    <time
      className="cv-ago"
      dateTime={new Date(at).toISOString()}
      title={new Date(at).toLocaleString(strings.language)}
    >
      {shortDuration(now - at, strings.language)}
    </time>
  );
}

export const machineLabel = (agent: { machine: string; machineName?: string | null }, strings: Strings) =>
  agent.machine === LOCAL_MACHINE ? strings.t("chiefViews.thisMac") : (agent.machineName ?? agent.machine);

export function PRChip({ number, onClick }: { number: number; onClick?: () => void }) {
  const text = `#${number}`;
  return onClick ? (
    <button type="button" className="cv-chip cv-pr" onClick={onClick}>
      {text}
    </button>
  ) : (
    <span className="cv-chip cv-pr">{text}</span>
  );
}

/** The dashboard's CI word for a pull request's run, in the page's words; nothing for one it does not know. */
export function CIChip({ status, strings }: { status?: string; strings: Strings }) {
  const kind = ciKind(status);
  if (!kind) return null;
  return (
    <span className="cv-chip cv-ci" data-ci={kind}>
      {strings.t(`chiefViews.ci.${kind}`)}
    </span>
  );
}

/** The agents on a pull request, as small name chips with their state. */
export function OwnerChips({ owners, strings }: { owners: readonly ChiefAgent[]; strings: Strings }) {
  if (owners.length === 0) return null;
  return (
    <span className="cv-owners">
      {owners.slice(0, 3).map((owner) => (
        <span key={owner.id} className="cv-chip cv-owner" data-state={owner.state} title={owner.title}>
          <StateMark state={owner.state} strings={strings} />
          <span className="cv-owner-name">{owner.name.split("/").at(-1)}</span>
        </span>
      ))}
      {owners.length > 3 && <span className="cv-chip cv-owner">+{owners.length - 3}</span>}
    </span>
  );
}

/**
 * One agent: state, title, machine and folder, its task line, the time since its last output and
 * its pull request. `compact` (a sidebar, a board card) drops the folder and wraps the task.
 */
export function AgentRow({
  agent,
  now,
  strings,
  compact,
  showMachine,
  prs,
  onOpen,
}: {
  agent: ChiefAgent;
  now: number;
  strings: Strings;
  compact?: boolean;
  showMachine?: boolean;
  prs?: ReadonlyMap<string, number>;
  onOpen: (agent: ChiefAgent) => void;
}) {
  const pr = agentPR(agent, prs);
  const folder = folderName(agent.folder);
  const line = agent.state === "failed" ? (agent.error ?? agent.task) : agent.task;
  const meta = (
    <span className="cv-row-meta">
      {compact && showMachine && <span className="cv-row-machine">{machineLabel(agent, strings)}</span>}
      {pr !== undefined && <PRChip number={pr} />}
      <Ago at={agent.lastOutputAt ?? agent.since} now={now} strings={strings} />
    </span>
  );
  return (
    <li className="cv-row" data-state={agent.state} data-kind={agent.kind} data-compact={compact ? "" : undefined}>
      <button type="button" className="cv-row-button" onClick={() => onOpen(agent)}>
        <StateMark state={agent.state} strings={strings} />
        <span className="cv-row-main">
          <span className="cv-row-head">
            <span className="cv-row-title">{agent.title}</span>
            {!compact && showMachine && <span className="cv-row-machine">{machineLabel(agent, strings)}</span>}
            {!compact && folder && (
              <span className="cv-row-folder" title={agent.folder ?? undefined}>
                {folder}
              </span>
            )}
          </span>
          {line && (
            <span className="cv-row-task" data-error={agent.state === "failed" ? "" : undefined}>
              {line}
            </span>
          )}
          {compact && meta}
        </span>
        {!compact && meta}
      </button>
    </li>
  );
}

/** A view's body while its data loads, failed or is missing; `children` once it is ready. */
export function Loaded({
  status,
  strings,
  children,
  unavailable,
}: {
  status: "idle" | "loading" | "ready" | "failed" | "unavailable";
  strings: Strings;
  children: ReactNode;
  unavailable?: ReactNode;
}) {
  if (status === "ready") return <>{children}</>;
  if (status === "unavailable")
    return <>{unavailable ?? <p className="cv-note">{strings.t("chiefViews.offline")}</p>}</>;
  if (status === "failed") return <p className="cv-note">{strings.t("chiefViews.failed")}</p>;
  return <p className="cv-note cv-loading">{strings.t("chiefViews.loading")}</p>;
}

const PATHS: Record<ChiefViewManifest["glyph"], string> = {
  // Three heads.
  people:
    "M5 7.5a2 2 0 1 1 0-4 2 2 0 0 1 0 4Zm6 0a2 2 0 1 1 0-4 2 2 0 0 1 0 4ZM1.5 13c0-2 1.6-3.5 3.5-3.5S8.5 11 8.5 13Zm6 0c0-2 1.6-3.5 3.5-3.5s3.5 1.5 3.5 3.5Z",
  // Three columns of cards.
  board: "M1.5 2.5h3.5v11h-3.5Zm4.75 0h3.5v7h-3.5Zm4.75 0h3.5v9h-3.5Z",
  // A rack of machines.
  fleet: "M2 2.5h12v3H2Zm0 4h12v3H2Zm0 4h12v3H2ZM3.5 3.5h1v1h-1Zm0 4h1v1h-1Zm0 4h1v1h-1Z",
  // A branch merging into a line.
  landing:
    "M4 2a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3Zm0 9a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3Zm8-6a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3ZM3.4 5h1.2v6H3.4Zm1 5.2C6 8.6 8.6 7.4 10.6 7l.3 1.1c-1.8.4-4.1 1.4-5.6 2.9Z",
  // A line of events.
  timeline: "M3 2h1.2v12H3Zm3 1h8v2H6Zm0 4h6v2H6Zm0 4h7v2H6ZM2 3.2h3.2v1H2Zm0 4h3.2v1H2Zm0 4h3.2v1H2Z",
};

export function ViewGlyph({ glyph, size = 16 }: { glyph: ChiefViewManifest["glyph"]; size?: number }) {
  return (
    <svg className="cv-glyph" width={size} height={size} viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
      <path d={PATHS[glyph]} fillRule="evenodd" />
    </svg>
  );
}
