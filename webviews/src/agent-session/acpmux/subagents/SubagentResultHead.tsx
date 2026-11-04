// A subagent's result head: the row under the child view's "Subagent of" pill (subagentRows.ts
// `childView`), so opening a subagent shows its result before its transcript, as ChatGPT's agent
// views do. Leo, 2026-11-04: "Opening a subagent shows its result first (medium). Put status,
// duration and its final report above its transcript, the way ChatGPT does." and "yeah but the big
// point is ofc the styling and theming and spacing too".
//
// One tool-row line on the transcript's grid: its mark in the icon column (the working spinner while
// it runs, never a dot; the error mark, the only red, when it failed; else the subagent's own mark),
// its state and how long it ran, and Copy at the line's end once there is a report. Under it the
// final report in the reply's type, on the column's left edge as a reply is, cut to REPORT_LINES with
// Show more when it is longer (the reader's choice kept across virtualization), and a hairline
// under the head that sets it off from the transcript below.
import { useContext, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useFindReveal } from "../conversation/chatFind";
import { Spinner } from "../conversation/icons";
import { Markdown } from "../conversation/Markdown";
import { MessageCopy } from "../conversation/MessageActions";
import { useTranscriptDisclosure } from "../conversation/transcriptDisclosure";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { AgentIdentity, SUBAGENT_FALLBACK } from "./AgentIdentity";
import { agentTone } from "./agentTones";
import { elapsed, STATE_LABEL, SubagentHarnessContext, useNow } from "./SubagentGroup";
import type { Subagent } from "./subagentFold";
import { subagentReport } from "./subagentRows";

/// Lines of the report shown before Show more (subagents.css `--cv-subagent-result-lines`; model.ts
/// estimates the same height).
export const REPORT_LINES = 12;

/// The state a result head names: running (a paused workflow reads as stopped, not running), else
/// how it ended.
export function resultState(agent: Subagent): keyof typeof STATE_LABEL {
  if (agent.state === "running") return agent.paused ? "cancelled" : "running";
  return agent.state in STATE_LABEL ? (agent.state as keyof typeof STATE_LABEL) : "completed";
}

export function SubagentResultRow({ row }: { row: AcpmuxRow }) {
  const agent = row.subagents?.[0];
  return agent ? <SubagentResultHead agent={agent} /> : null;
}

export function SubagentResultHead({ agent }: { agent: Subagent }) {
  const t = useT();
  const chatHarness = useContext(SubagentHarnessContext);
  const state = resultState(agent);
  const live = state === "running";
  const now = useNow(live);
  const report = subagentReport(agent);
  // An ended one that recorded no end has no honest duration: none is shown.
  const time = live || agent.endedAt !== undefined ? formatDuration(elapsed(agent, now)) : undefined;
  return (
    <section className="cv-subagent-result" data-state={state} aria-label={agent.task?.trim() || agent.name}>
      <div className="cv-tool cv-subagent-result__head">
        <span className="cv-tool__icon cv-subagent-result__mark" aria-hidden>
          {live ? (
            <Spinner size={14} loading />
          ) : state === "failed" ? (
            <Icon name="status.error" size={14} />
          ) : (
            <AgentIdentity
              harness={agent.harness ?? chatHarness}
              tone={agentTone(agent.id)}
              size={16}
              fallback={SUBAGENT_FALLBACK}
            />
          )}
        </span>
        <span className="cv-tool__text cv-subagent-result__status">
          <span className="cv-subagent-result__state">{t(STATE_LABEL[state])}</span>
          {time && <span className="cv-subagent-result__time">{` · ${time}`}</span>}
        </span>
        {report && (
          <span className="cv-subagent-result__actions">
            <MessageCopy text={report} />
          </span>
        )}
      </div>
      {report && <Report agent={agent} text={report} />}
    </section>
  );
}

/// The final report, cut to REPORT_LINES lines until Show more; whether it is longer is measured,
/// since the pane's width decides the wrap (one observer, gone with the report).
function Report({ agent, text }: { agent: Subagent; text: string }) {
  const t = useT();
  const [open, setOpen] = useTranscriptDisclosure(`subagent-result:${agent.id}`);
  const [long, setLong] = useState(false);
  useFindReveal(
    useMemo((): AcpmuxActivity[] => [{ kind: "note", text }], [text]),
    () => setOpen(true),
  );
  const ref = useRef<HTMLDivElement>(null);
  const id = useId();
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || open) return;
    const measure = () => setLong(node.scrollHeight - node.clientHeight > 1);
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [text, open]);
  return (
    <div className="cv-subagent-result__body">
      <div
        ref={ref}
        id={id}
        className="cv-subagent-result__report selectable"
        data-cut={open ? undefined : true}
        data-more={long && !open ? true : undefined}
      >
        <Markdown commits="quiet">{text}</Markdown>
      </div>
      {(long || open) && (
        <button
          type="button"
          className="cv-subsession__toggle cv-subagent-result__toggle"
          aria-expanded={open}
          aria-controls={id}
          onClick={() => setOpen((value) => !value)}
        >
          {t(open ? "message.less" : "message.more")}
        </button>
      )}
    </div>
  );
}
