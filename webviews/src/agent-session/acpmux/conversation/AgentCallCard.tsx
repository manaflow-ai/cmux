// A Claude Code Task or Agent call no subagent record claimed (agentCalls.ts) as the subagent it ran,
// never a plain "Agent: …" tool row: one line with the subagent's mark, its kind and what it was
// asked to do, then its state and time ("Done · 1m 12s · 14 tool uses"). Opened, its report as
// Markdown cut to three lines, and the prompt it got behind "Show prompt"; while it runs, the prompt.
// The line keeps a tool row's height, so the transcript row stays compact (Leo, 2026-11-05: "could we
// potentially do even better?"). The same web draws it on the Mac and the phone.
import { useContext, useId, useMemo, useState } from "react";
import { usePageNow } from "../../../ui/pageClock";
import { useT, type Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { AgentIdentity, SUBAGENT_FALLBACK } from "../subagents/AgentIdentity";
import { agentTone } from "../subagents/agentTones";
import { DisclosureRow } from "../subagents/DisclosureRow";
import { SubagentHarnessContext } from "../subagents/SubagentGroup";
import { SUBSESSION_STATE_LABEL } from "../subagents/subsessions";
import type { AgentCall } from "./agentCalls";
import { CardCopy } from "./CardCopy";
import { useFindReveal } from "./chatFind";
import { compactTokens } from "./CompactionNote";
import { Spinner } from "./icons";
import { Markdown } from "./Markdown";
import { Cut } from "./SubsessionCallCard";
import { formatDuration } from "./turns";
import "./AgentCallCard.css";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// How the card draws: `report` (the line, then the report with the prompt behind a toggle),
/// `stacked` (the prompt and the report both shown, one over the other) or `preview` (as `report`,
/// with the report's first line under the closed line). The gallery compares them
/// (AgentCallCard.gallery.tsx); the pane draws `report`.
export type AgentCallLook = "report" | "stacked" | "preview";

export function AgentCallCard({ call, tool, look = "report" }: { call: AgentCall; tool: Tool; look?: AgentCallLook }) {
  const t = useT();
  const harness = useContext(SubagentHarnessContext) ?? "claude";
  const now = usePageNow(call.running);
  const findItems = useMemo((): AcpmuxActivity[] => [{ kind: "tool", text: tool.title, tool }], [tool]);
  const state = call.running ? "working" : call.failed ? "failed" : "done";
  const status = (
    <span className="cv-agentcall__status" data-state={state}>
      {call.running && <Spinner size={12} loading />}
      {[t(SUBSESSION_STATE_LABEL[state]), ...statusParts(t, call, tool, now)].join(" · ")}
    </span>
  );
  const label = (
    <>
      {call.type && <span className="cv-agentcall__type">{call.type}</span>}
      {call.type && " "}
      {call.description}
    </>
  );
  const preview = look === "preview" && call.report ? firstWords(call.report) : undefined;
  return (
    <DisclosureRow
      className="cv-agentcall"
      disclosureKey={`agent-call:${tool.id}`}
      findItems={findItems}
      icon={
        <span className="cv-subagent-avatar" data-state={call.running ? "running" : state}>
          <AgentIdentity harness={harness} tone={agentTone(tool.id)} size={14} fallback={SUBAGENT_FALLBACK} />
        </span>
      }
      label={label}
      status={status}
      below={preview}
    >
      <AgentCallBody call={call} tool={tool} look={look} />
    </DisclosureRow>
  );
}

function AgentCallBody({ call, tool, look }: { call: AgentCall; tool: Tool; look: AgentCallLook }) {
  const { prompt, report } = call;
  if (look === "stacked" || !report)
    return (
      <>
        {prompt && <Cut text={prompt} prompt disclosureKey={`agent-call-prompt:${tool.id}`} />}
        {report && <hr className="cv-agentcall__rule" />}
        {report && <CardCopy text={report} />}
        {report && <Cut text={report} disclosureKey={`agent-call-report:${tool.id}`} />}
      </>
    );
  return (
    <>
      <CardCopy text={report} />
      <Cut text={report} disclosureKey={`agent-call-report:${tool.id}`} />
      {prompt && <PromptToggle prompt={prompt} />}
    </>
  );
}

/// The prompt the subagent got, whole, behind "Show prompt" under its report; Find opens it on a match.
function PromptToggle({ prompt }: { prompt: string }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const id = useId();
  useFindReveal(
    useMemo((): AcpmuxActivity[] => [{ kind: "note", text: prompt }], [prompt]),
    () => setOpen(true),
  );
  return (
    <div className="cv-agentcall__prompt">
      <button
        type="button"
        className="cv-subsession__toggle"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        {t(open ? "message.less" : "subsession.showPrompt")}
      </button>
      {open && (
        <div id={id} className="cv-subsession__markdown selectable">
          <Markdown commits="quiet">{prompt}</Markdown>
        </div>
      )}
    </div>
  );
}

/// After the state: how long it has run or ran (Claude's own `duration_ms` once it reports one, else
/// the call's own times), then its tool uses and tokens when the result says them.
function statusParts(t: Translate, call: AgentCall, tool: Tool, now: number): string[] {
  const end = call.running ? now : tool.endedAt;
  const ms = call.durationMs ?? (tool.startedAt !== undefined && end !== undefined ? end - tool.startedAt : undefined);
  return [
    ms !== undefined && ms >= 1000 ? formatDuration(ms) : undefined,
    call.toolUses !== undefined ? t("subagents.toolUses", { n: call.toolUses }) : undefined,
    call.tokens !== undefined
      ? t("subagents.tokens", { n: call.tokens, tokens: compactTokens(call.tokens) })
      : undefined,
  ].filter((part): part is string => part !== undefined);
}

/// The report's first line of words, for the closed line's preview: no Markdown marks before it.
const firstWords = (report: string) =>
  report
    .split("\n")
    .map((line) => line.replace(/^\s*(?:#+|[-*>]|\d+\.)\s*/u, "").trim())
    .find(Boolean);
