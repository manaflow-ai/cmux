// The whole run of one agent turn, over the timeline from the end edge (the thread sheet's place):
// the status, who ran it, the time, tokens and cost, then every step in order. Reply segments draw
// as Markdown, tool calls with the agent pane's rows (output, Shell block, diff), each step's links
// and pictures below it; a thought is folded (its text only when opened). A running run keeps
// streaming here.
import { useEffect, useMemo } from "react";
import type { Strings } from "../shared/i18n";
import { KeyboardScope } from "../../ui/KeyboardScope";
import { RunSteps } from "./RunSteps";
import { Avatar } from "./Avatar";
import { HomeIcon } from "./icons";
import { participantNames, RunMark, runLabel, shownStatus, useNow } from "./RunCard";
import { runCost, runTokens, type RunEntry } from "./runs";
import type { HomeParticipant, HomeRun } from "./types";

export interface RunSheetProps {
  entry: RunEntry;
  people: ReadonlyMap<string, HomeParticipant>;
  strings: Strings;
  /** Where the run is (the conversation's name). */
  place: string;
  /** The first line of the message the run works on: the title when the run has none. */
  asked?: string;
  onClose(): void;
  /** Reads the rest of the run's steps from the owner. */
  onLoad(run: HomeRun): void;
}

export function RunSheet({ entry, people, strings, place, asked, onClose, onLoad }: RunSheetProps) {
  const { t, format } = strings;
  const { run, steps } = entry;
  const now = useNow(run.status === "running");
  const status = shownStatus(run, now);
  const running = status === "running";
  useEffect(() => {
    if (!entry.complete) onLoad(run);
  }, [entry.complete, run, onLoad]);
  const agentNames = useMemo(() => participantNames(people), [people]);
  const author = people.get(run.author)?.name ?? run.author;
  const cost = runCost(run.costUsd);
  const tokens = runTokens(run);
  return (
    <KeyboardScope
      handleKeyDown={(event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          onClose();
        }
      }}
    >
      <aside className="lg-sheet lg-run-sheet" data-status={status} aria-label={run.title || t("run.title")}>
        <header className="lg-sheet-header">
          <div className="lg-sheet-bar">
            <span className={`lg-run-status ${status}`}>
              <RunMark status={status} />
              {t(`run.status.${status}`)}
            </span>
            <span className="lg-sheet-place">{place}</span>
            <span className="lg-spacer" />
            <button type="button" className="hc-icon-button" aria-label={t("run.close")} onClick={onClose}>
              <HomeIcon name="close" size={16} />
            </button>
          </div>
          <h2 className="lg-sheet-title">{run.title || asked || format("run.by", author)}</h2>
          <p className="lg-sheet-meta">
            <span className="lg-run-author">
              <Avatar participant={people.get(run.author)} size={16} />
              {author}
            </span>
            <span>{runLabel(run, now, strings)}</span>
            {run.stepCount > 0 && (
              <span>{run.stepCount === 1 ? t("run.steps.one") : format("run.steps.many", String(run.stepCount))}</span>
            )}
            {tokens && <span>{format("run.tokens", tokens)}</span>}
            {cost && <span title={t("run.cost.hint")}>{format("run.cost", cost)}</span>}
            {run.model && <span>{run.model}</span>}
          </p>
        </header>
        <div className="lg-run-body">
          {steps.length === 0 && <p className="lg-run-empty">{running ? t("run.starting") : t("run.empty")}</p>}
          <RunSteps run={run} steps={steps} agentNames={agentNames} />
          {run.status === "failed" && run.error && (
            <p className="lg-run-error" role="alert">
              {run.error}
            </p>
          )}
          {run.session && (
            <p className="lg-run-session">
              {format("run.session", run.session.kind)} <code>{run.session.id}</code>
            </p>
          )}
        </div>
      </aside>
    </KeyboardScope>
  );
}
