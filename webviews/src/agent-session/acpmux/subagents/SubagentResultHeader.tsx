// The compact result head shown when a completed subagent opens. It keeps the final report in view
// above the full transcript, matching ChatGPT's result-first drill-in without hiding any rows.
import { useContext, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { CopyButton } from "../conversation/CopyButton";
import { useFindReveal } from "../conversation/chatFind";
import { Spinner } from "../conversation/icons";
import { Markdown } from "../conversation/Markdown";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxActivity } from "../model";
import { AgentIdentity, SUBAGENT_FALLBACK } from "./AgentIdentity";
import { agentTone } from "./agentTones";
import type { Subagent } from "./subagentFold";
import { STATE_LABEL, SubagentHarnessContext, elapsed, running, useNow } from "./SubagentGroup";
import { useTranscriptDisclosure } from "../conversation/transcriptDisclosure";


function resultState(agent: Subagent): keyof typeof STATE_LABEL {
  if (agent.state === "running") return agent.paused ? "cancelled" : "running";
  return agent.state in STATE_LABEL ? (agent.state as keyof typeof STATE_LABEL) : "completed";
}

function reportFor(agent: Subagent): string | undefined {
  if (agent.state === "running") return undefined;
  return agent.result?.trim() || agent.lastMessage?.trim() || agent.error?.trim() || undefined;
}

function ResultReport({ agent, text }: { agent: Subagent; text: string }) {
  const t = useT();
  const [open, setOpen] = useTranscriptDisclosure(`subagent-result:${agent.id}`, false);
  const [long, setLong] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const id = useId();
  const findItems = useMemo((): AcpmuxActivity[] => [{ kind: "note", text }], [text]);
  useFindReveal(findItems, () => setOpen(true));
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || open) return;
    const measure = () => setLong(node.scrollHeight - node.clientHeight > 1);
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [open, text]);
  return (
    <div className="cv-subagent-result__body">
      <div
        ref={ref}
        id={id}
        className="cv-subagent-result__report"
        data-cut={!open ? true : undefined}
        data-more={long && !open ? true : undefined}
      >
        <Markdown>{text}</Markdown>
      </div>
      {(long || open) && (
        <button
          type="button"
          className="cv-subagent-result__toggle"
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

export function SubagentResultHeader({ agent }: { agent: Subagent }) {
  const t = useT();
  const live = running(agent);
  const now = useNow(live);
  const chatHarness = useContext(SubagentHarnessContext);
  const stateKey = resultState(agent);
  const report = reportFor(agent);
  const state = t(STATE_LABEL[stateKey]);
  const duration = formatDuration(elapsed(agent, live ? now : (agent.endedAt ?? agent.startedAt)));
  const copy = useMemo(
    () => report ?? "",
    [report],
  );
  return (
    <section className="cv-subagent-result" data-state={stateKey}>
      <div className="cv-subagent-result__meta cv-subagent-result__head">
        <span className="cv-subagent-result__mark" aria-hidden="true">
          {stateKey === "running" ? (
            <Spinner size={14} loading />
          ) : stateKey === "failed" ? (
            <Icon name="status.error" size={14} />
          ) : (
            <AgentIdentity harness={agent.harness ?? chatHarness} tone={agentTone(agent.id)} size={16} fallback={SUBAGENT_FALLBACK} />
          )}
        </span>
        <span className="cv-subagent-result__state">{state}</span>
        <span className="cv-subagent-result__time">{` · ${duration}`}</span>
        {copy && <CopyButton text={copy} label={t("turn.copy")} className="cv-iconbtn cv-iconbtn--compact" />}
      </div>
      {report && <ResultReport agent={agent} text={report} />}
    </section>
  );
}
