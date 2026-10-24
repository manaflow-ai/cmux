// An agent run in the conversation: under the reply it ended with, or under the message it works
// on while it runs. One quiet line (a status mark, "Working for 42s" or "Worked for 1m 12s", the
// step count, the tokens) opens the run's last steps below; "Open" shows the whole run in the run
// sheet. Tool calls and thoughts draw with the agent pane's own rows (ToolRows), so a run reads the
// same here as in the agent pane.
import { createContext, useContext, useEffect, useMemo, useState } from "react";
import { AgentNamesContext } from "../../agent-session/acpmux/conversation/agentNames";
import { ChevronRight } from "../../agent-session/acpmux/conversation/icons";
import { ToolRows } from "../../agent-session/acpmux/conversation/TurnRows";
import { formatDuration } from "../../agent-session/acpmux/conversation/turns";
import type { AcpmuxActivity, AcpmuxRow } from "../../agent-session/acpmux/model";
import type { Strings } from "../shared/i18n";
import { liveReply, tail, useLiveRun, type LiveBook } from "./live";
import { isStale, runTokens, useLiveRuns, useRunEntry, type RunBook, type RunEntry } from "./runs";
import { Avatar } from "./Avatar";
import type { HomeMessage, HomeParticipant, HomeRun, HomeRunStep } from "./types";

/** How many of a run's newest steps the card shows. */
const CARD_STEPS = 3;
const EMPTY_AGENT_NAMES: ReadonlyMap<string, string> = new Map();

/** Names available to a Channels run's shared MessageCard rows. */
export function participantNames(people?: ReadonlyMap<string, HomeParticipant>): ReadonlyMap<string, string> {
  if (!people || people.size === 0) return EMPTY_AGENT_NAMES;
  return new Map([...people].map(([id, participant]) => [id, participant.name]));
}

/** A tool or thought step as the agent pane's activity item (ToolRow, ThoughtRow). */
export function stepActivity(step: HomeRunStep): AcpmuxActivity {
  if (step.kind !== "tool" || !step.tool) return { kind: "thought", text: step.text ?? "" };
  const tool = step.tool;
  const input = tool.input && typeof tool.input === "object" ? (tool.input as Record<string, unknown>) : undefined;
  const command = typeof input?.command === "string" ? input.command : undefined;
  return {
    kind: "tool",
    text: tool.title ?? tool.name,
    status: step.status,
    tool: {
      id: step.id,
      title: tool.title ?? tool.name,
      kind: tool.kind,
      status: step.status === "done" ? "completed" : step.status === "failed" ? "failed" : "in_progress",
      inputSummary: input ? summary(input) : typeof tool.input === "string" ? tool.input : undefined,
      output: tool.output,
      command,
      exitCode: tool.exitCode,
      startedAt: tool.startedAt,
      endedAt: tool.endedAt,
      diffs: tool.files
        .filter((file) => file.newText !== undefined)
        .map((file) => ({ path: file.path, oldText: file.oldText, newText: file.newText!, line: file.line })),
      locations: tool.files.map((file) => ({ path: file.path, line: file.line })),
    },
  };
}

function summary(input: Record<string, unknown>): string {
  for (const key of ["command", "file_path", "path", "pattern", "url", "query", "description"]) {
    const value = input[key];
    if (typeof value === "string" && value) return value;
  }
  return JSON.stringify(input).slice(0, 200);
}

/** Consecutive tool steps as one agent-pane activity row; text and thought steps between them. */
export type RunBlock =
  | { kind: "tools"; key: string; row: AcpmuxRow }
  | { kind: "talk"; key: string; step: HomeRunStep }
  | { kind: "thought"; key: string; step: HomeRunStep }
  | { kind: "note"; key: string; step: HomeRunStep };

export function runBlocks(run: HomeRun, steps: readonly HomeRunStep[]): RunBlock[] {
  const blocks: RunBlock[] = [];
  let items: AcpmuxActivity[] = [];
  let first: HomeRunStep | undefined;
  const flush = () => {
    if (!first || items.length === 0) return;
    blocks.push({
      kind: "tools",
      key: `tools-${first.id}`,
      row: {
        id: `${run.id}:${first.id}`,
        version: run.rev,
        at: first.at,
        kind: "activity",
        items,
        // Every call on its own row: a run is read step by step, never folded into one line.
        settled: false,
      },
    });
    items = [];
    first = undefined;
  };
  for (const step of steps) {
    if (step.kind === "tool") {
      first ??= step;
      items.push(stepActivity(step));
    } else {
      flush();
      blocks.push({ kind: step.kind, key: step.id, step });
    }
  }
  flush();
  return blocks;
}

/** Ticks once a second while `running` (the "Working for" clock); a finished run holds still. */
export function useNow(running: boolean): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!running) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [running]);
  return now;
}

/** "Working for 42s" / "Worked for 1m 12s" / "Failed after 8s" / "Stopped after 3s", or
 * "No update for 34m" for a running run that stopped answering. */
export function runLabel(run: HomeRun, now: number, strings: Strings): string {
  if (isStale(run, now)) return strings.format("run.label.stale", formatDuration(now - run.updatedAt));
  const ms = (run.endedAt ?? now) - run.startedAt;
  const time = formatDuration(Math.max(0, ms));
  return strings.format(`run.label.${run.status}`, time);
}

/** A run's status as it shows: a stalled running run is `stale`. */
export const shownStatus = (run: HomeRun, now: number): HomeRun["status"] | "stale" =>
  isStale(run, now) ? "stale" : run.status;

export function RunMark({ status }: { status: HomeRun["status"] | "stale" }) {
  return <span className={`lg-run-mark ${status}`} aria-hidden="true" />;
}

export interface RunCardProps {
  entry: RunEntry;
  /** The run's author (a Chief): its picture leads the card. */
  author?: HomeParticipant;
  strings: Strings;
  /** Opens the run sheet. */
  onOpen(run: HomeRun): void;
  /** Reads the run's steps from the owner (a run the page has only a summary of). */
  onLoad(run: HomeRun): void;
  /** The page's live run text (`chief-live-v1`): a running run shows its reply as it streams. */
  live?: LiveBook;
  /** The turn of the draft row the timeline shows. */
  draftTurn?: string;
  /** Names for SendMessage recipients in the shared agent-message rows. */
  agentNames?: ReadonlyMap<string, string>;
}

/** How much of a streaming reply the card shows: its end, about two lines. */
const CARD_LIVE_CHARS = 240;

export function RunCard({ entry, author, strings, onOpen, onLoad, live, draftTurn, agentNames }: RunCardProps) {
  const { run, steps } = entry;
  const now = useNow(run.status === "running");
  const status = shownStatus(run, now);
  const running = status === "running";
  const streamed = useLiveRun(live, run.conversation, run.author, run.id);
  // A reply the timeline shows as a draft row is not repeated here.
  const reply = running && !(draftTurn && run.turn === draftTurn) ? liveReply(streamed) : "";
  const [open, setOpen] = useState(running);
  // A run the page knows only by its summary reads its steps once it is opened (or while it runs).
  useEffect(() => {
    if ((open || running) && !entry.complete && steps.length < run.stepCount) onLoad(run);
  }, [open, running, entry.complete, steps.length, run, onLoad]);
  // A finished run folds; one that starts again opens.
  useEffect(() => {
    if (running) setOpen(true);
  }, [running]);
  // The card shows tool calls only: a thought stays in the run sheet, folded.
  const shown = useMemo(() => {
    const work = steps.filter((step) => step.kind === "tool");
    return runBlocks(run, work.slice(-CARD_STEPS));
  }, [run, steps]);
  const count = run.stepCount;
  // Tokens, not dollars: most runs go through a subscription or a router, where the harness's dollar
  // figure (pay-per-token API prices) is not what anyone pays. The run sheet keeps it, labelled.
  const tokens = runTokens(run);
  return (
    <section className={`lg-run ${status}`} aria-label={run.title || strings.t("run.title")} aria-busy={running}>
      <div className="lg-run-bar">
        <button type="button" className="lg-run-toggle" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
          {author && <Avatar participant={author} size={16} />}
          <RunMark status={status} />
          <span className="lg-run-label">{runLabel(run, now, strings)}</span>
          {(count > 0 || tokens) && (
            // One line with the label when the card is wide; its own line under it when narrow.
            <span className="lg-run-metas">
              {count > 0 && (
                <span className="lg-run-meta">
                  {count === 1 ? strings.t("run.steps.one") : strings.format("run.steps.many", String(count))}
                </span>
              )}
              {tokens && <span className="lg-run-meta">{strings.format("run.tokens", tokens)}</span>}
            </span>
          )}
          <ChevronRight size={14} strokeWidth={1.2} className={`lg-run-chevron cv-rotor${open ? " is-open" : ""}`} />
        </button>
        <button type="button" className="lg-link-button lg-run-open" onClick={() => onOpen(run)}>
          {strings.t("run.open")}
        </button>
      </div>
      {run.title && <p className="lg-run-title">{run.title}</p>}
      {reply && (
        <p className="lg-run-live" dir="auto">
          {tail(reply, CARD_LIVE_CHARS)}
        </p>
      )}
      {open && shown.length > 0 && (
        <div className="lg-run-steps">
          {count > shown.length && <p className="lg-run-more">{strings.t("run.earlier")}</p>}
          {shown.map((block) =>
            block.kind === "tools" ? (
              <AgentNamesContext.Provider key={block.key} value={agentNames ?? EMPTY_AGENT_NAMES}>
                <ToolRows row={block.row} />
              </AgentNamesContext.Provider>
            ) : null,
          )}
        </div>
      )}
      {run.status === "failed" && run.error && (
        <p className="lg-run-error" role="alert">
          {run.error}
        </p>
      )}
    </section>
  );
}

/** What a message row needs to show runs: the page's run book and the sheet's actions. */
export interface RunsContextValue {
  book: RunBook;
  strings: Strings;
  /** The participants by id: a card shows its author's picture. */
  people?: ReadonlyMap<string, HomeParticipant>;
  onOpen(run: HomeRun): void;
  onLoad(run: HomeRun): void;
  /** The page's live run text (`chief-live-v1`). */
  live?: LiveBook;
  /** The turn of the draft row the open conversation shows. */
  draftTurn?: string;
}

export const RunsContext = createContext<RunsContextValue | undefined>(undefined);

/** The runs of one message row: the run its reply ended (an agent's message), then the runs
 * still working on it (or that ended with no reply). */
export function MessageRuns({ message }: { message: HomeMessage }) {
  const context = useContext(RunsContext);
  const reply = useRunEntry(context?.book, (book) => book.forReply(message));
  const live = useLiveRuns(context?.book, message);
  const names = useMemo(() => participantNames(context?.people), [context?.people]);
  if (!context || (!reply && live.length === 0)) return null;
  const card = (entry: RunEntry) => (
    <RunCard
      key={`${entry.run.author}:${entry.run.id}`}
      entry={entry}
      author={context.people?.get(entry.run.author)}
      strings={context.strings}
      onOpen={context.onOpen}
      onLoad={context.onLoad}
      live={context.live}
      draftTurn={context.draftTurn}
      agentNames={names}
    />
  );
  return (
    <>
      {reply && card(reply)}
      {live.filter((entry) => entry !== reply).map(card)}
    </>
  );
}
