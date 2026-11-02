// A call to the cmux-subsessions tools (subsessionCalls.ts) as the sub-sessions it touched, never
// its JSON: a start as the sub-session's card (subagents/AgentCard.tsx) over its prompt as Markdown
// cut to three lines; a wait or a list as each one's card, a finished one's reply under it; a
// message as "Sent message to tests" and its first line (SentMessageLine.tsx, the row a shell
// `acpmux send` draws too), which opens to all of it. Each card reads its state live from
// the session list (subagents/subsessions.ts). The call's JSON stays behind "Raw"; the prompt or
// reply a card shows copies from its top-right corner (CardCopy.tsx).
import type { ReactNode } from "react";
import { useContext, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { type Translate, useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { AgentCard } from "../subagents/AgentCard";
import { DisclosureRow } from "../subagents/DisclosureRow";
import { AgentIdentity } from "../subagents/AgentIdentity";
import { agentTone } from "../subagents/agentTones";
import {
  SubsessionContext,
  useSenderChat,
  useSubsessionInfo,
  useSubsessionInfos,
  waitingLine,
} from "../subagents/subsessions";
import { retryLabel, sessionRetry } from "../subagents/retryState";
import { useFindReveal } from "./chatFind";
import { Spinner } from "./icons";
import { Markdown } from "./Markdown";
import { McpCallDetails } from "./McpCallRows";
import { mcpCall, mcpRawName } from "./mcpCalls";
import { CardCopy } from "./CardCopy";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { RawToggle, SentMessageLine } from "./SentMessageLine";
import type { SubsessionCall, SubsessionDelivery, SubsessionReply } from "./subsessionCalls";
import "./SubsessionCallCard.css";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const toolActivity = (tool: Tool): AcpmuxActivity => ({ kind: "tool", text: tool.title, tool });

export type StartedGroupEntry = {
  call: Extract<SubsessionCall, { tool: "start" }>;
  tool: Tool;
};

export function SubsessionCallCard({
  call,
  tool,
  group,
}: {
  call?: SubsessionCall;
  tool?: Tool;
  group?: readonly StartedGroupEntry[];
}) {
  if (group) return <StartedGroup entries={group} />;
  if (!call || !tool) return null;
  switch (call.tool) {
    case "start":
      return <StartedCard call={call} tool={tool} />;
    case "send":
      return <SentLine call={call} tool={tool} />;
    case "wait":
    case "list":
      return <SessionCards call={call} tool={tool} />;
  }
}

function StartedGroup({ entries }: { entries: readonly StartedGroupEntry[] }) {
  const t = useT();
  const names = entries.map(
    ({ call }) => call.name ?? (call.sessionId ? shortId(call.sessionId) : t("subsession.startingBare")),
  );
  const ids = useMemo(() => entries.map(({ call }) => call.sessionId), [entries]);
  const children = useSubsessionInfos(ids);
  const findItems = useMemo(() => entries.map(({ tool }) => toolActivity(tool)), [entries]);
  let working = false;
  let waiting = 0;
  let failed = 0;
  let done = 0;
  for (const [index, child] of children.entries()) {
    const phase = child && sessionRetry(child);
    if (child?.slot || child?.state === "input") waiting++;
    else if (phase?.kind === "retrying" || phase?.kind === "settling" || child?.state === "working") working = true;
    else if (child?.state === "failed") failed++;
    else if (child?.state === "done") done++;
    else if (entries[index]?.call.running) working = true;
  }
  const status = [
    waiting ? t("summary.subagents.waiting", { n: waiting }) : undefined,
    failed ? t("summary.subagents.failed", { n: failed }) : undefined,
    working ? t("subsession.state.working") : undefined,
    children.length > 0 && done === children.length ? t("subagents.state.completed") : undefined,
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <DisclosureRow
      disclosureKey={`subsession-group:${entries[0]?.tool.id}`}
      findItems={findItems}
      icon={
        <AgentIdentity
          harness={children.find(Boolean)?.harness}
          tone={agentTone(entries.map(({ call }) => call.sessionId ?? "").join("\u0000"))}
          size={16}
        />
      }
      label={t("subsession.startedGroup", { n: entries.length, names: names.join(", ") })}
      status={
        status ? (
          <>
            {working && <Spinner size={12} loading />}
            {status}
          </>
        ) : undefined
      }
    >
      {entries.map(({ call, tool }, index) => (
        <StartedCard key={tool.id || index} call={call} tool={tool} />
      ))}
    </DisclosureRow>
  );
}

/// A call still running: one line with the working spinner.
function RunningLine({ children }: { children: ReactNode }) {
  return (
    <div className="cv-tool cv-subsession is-live">
      <span className="cv-tool__icon">
        <Spinner size={16} loading />
      </span>
      <span className="cv-tool__text">{children}</span>
    </div>
  );
}

/// The card's line for a session not waiting: what it does now, or, failed, why. Only a `doing` line
/// that repeats the prompt shown under the card is left out; an error always stays, even one that
/// starts like the prompt (Codex review of #27240), and stands in for a `doing` line left out.
export function sessionLine(
  doing: string | undefined,
  error: string | undefined,
  failed: boolean,
  shown?: string,
): string | undefined {
  const step = doing && !(shown && repeatsPrompt(doing, shown)) ? doing : undefined;
  return step ?? (failed ? error : undefined);
}

/// Whether a session's `doing` line only repeats the start of the prompt shown under it: acpmux
/// names a new session from its prompt, so its first line is that prompt's opening words, often cut
/// with an ellipsis. Compared on words, ignoring whitespace, case and a trailing ellipsis.
export function repeatsPrompt(line: string, prompt: string): boolean {
  // The line as it came first: a prompt may itself start with "Working on:". Then without acpmux's
  // own prefix for a session with no step yet, "Working on: <prompt, cut>" (hub/subsession_send.rs).
  const bare = line.replace(/^\s*Working on:\s*/iu, "");
  return startsPrompt(line, prompt) || (bare !== line && startsPrompt(bare, prompt));
}

/// Whether `line` is the start of `prompt`, word for word, ignoring case and whitespace. Only a line
/// that says it is cut (it ends in an ellipsis) may stop mid-word, so a real step ("Fix bug") never
/// hides behind its prompt ("Fix bugs ...").
function startsPrompt(line: string, prompt: string): boolean {
  const ellipsis = /(?:\.\.\.|\u2026)\s*$/u;
  const cut = ellipsis.test(line);
  const words = (text: string) => text.replace(ellipsis, "").toLowerCase().split(/\s+/u).filter(Boolean);
  const head = words(line);
  if (head.length === 0) return false;
  const body = words(prompt).slice(0, head.length);
  if (body.length < head.length) return false;
  return head.every((word, index) =>
    cut && index === head.length - 1 ? body[index]!.startsWith(word) : body[index] === word,
  );
}

/// The live card of sub-session `sessionId`, with what the call knew of it until the list has it.
function SessionCard({
  tool,
  sessionId,
  name,
  harness,
  model,
  fallback,
  shown,
  disclosure = false,
  disclosureKey,
  children,
}: {
  tool: Tool;
  /// The prompt the card shows under its header (a start's preview): a `doing` line that only
  /// repeats its start is left out, so the same words never show twice (Leo 2026-10-29).
  shown?: string;
  sessionId?: string;
  name: string;
  harness?: string;
  model?: string;
  /// Its state as the call read it, for a session the list does not have.
  fallback?: Pick<SubsessionReply, "state" | "waiting" | "slot">;
  disclosure?: boolean;
  disclosureKey?: string;
  children?: ReactNode;
}) {
  const t = useT();
  const live = useSubsessionInfo(sessionId);
  const findItems = useMemo(() => [toolActivity(tool)], [tool]);
  const listed = useSenderChat("", sessionId).harness;
  const open = useContext(SubsessionContext)?.open;
  // The card's retry, as every surface reads it (retryState.ts ``sessionRetry``): while acpmux
  // retries its failed turn, the card works, and its state says so. Its Retry is on its end line.
  const phase = live ? sessionRetry(live) : undefined;
  const retry = phase?.kind === "retrying" ? phase.retry : undefined;
  const state = retry ? "working" : (live?.state ?? fallback?.state);
  const waiting = live ? live.waiting : fallback?.waiting;
  // A failed one says why (acpmux's lane error), a retry acpmux refused included.
  const doing = waiting ? waitingLine(t, waiting) : sessionLine(live?.doing, live?.error, state === "failed", shown);
  return (
    <AgentCard
      name={live?.name ?? name}
      harness={listed ?? harness}
      sessionId={sessionId}
      model={live?.model ?? model}
      state={state}
      {...(retry && { stateLabel: retryLabel(t, retry) })}
      slot={live ? live.slot === true : fallback?.slot === true}
      doing={doing}
      queued={live?.queued}
      disclosure={disclosure}
      disclosureKey={disclosureKey}
      findItems={findItems}
      // The row is the session's name by its harness's mark, no "Started sub-session" in front of it
      // (design/chat-transcript.md: no narration, the icon names the type; transcript audit HQ#5154).
      onOpen={sessionId && open ? () => open(sessionId) : undefined}
    >
      {children}
    </AgentCard>
  );
}

function StartedCard({ call, tool }: { call: Extract<SubsessionCall, { tool: "start" }>; tool: Tool }) {
  const t = useT();
  const promptFindId = useId();
  return (
    <SessionCard
      tool={tool}
      sessionId={call.sessionId}
      name={call.name ?? (call.sessionId ? shortId(call.sessionId) : t("subsession.startingBare"))}
      harness={call.harness}
      model={call.model}
      // Until the call returns, the sub-session is starting: the working spinner.
      fallback={call.running ? { state: "working" } : undefined}
      shown={call.prompt}
      disclosure={true}
      disclosureKey={`subsession-start:${tool.id}`}
    >
      {call.prompt && <CardCopy text={call.prompt} />}
      {call.prompt && (
        <div className="cv-subsession__markdown selectable" data-find-primary={promptFindId}>
          <Markdown commits="quiet">{call.prompt}</Markdown>
        </div>
      )}
      <Raw tool={tool} promptFindId={call.prompt ? promptFindId : undefined} />
    </SessionCard>
  );
}

/// Markdown cut to its first three lines, with a toggle to show the rest when there is more (a
/// prompt's "Show prompt"). Whether there is more is measured: the pane's width decides the wrap,
/// so a resize can bring the toggle in or take it away (one observer per cut, gone with it).
/// Keep the reader's choice when the card closes or the transcript virtualizes this result.
export function Cut({ text, prompt, disclosureKey }: { text: string; prompt?: boolean; disclosureKey: string }) {
  const t = useT();
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey);
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
    <div className="cv-subsession__cut">
      <div
        ref={ref}
        id={id}
        className="cv-subsession__markdown selectable"
        data-cut={open ? undefined : true}
        data-more={long && !open ? true : undefined}
      >
        <Markdown commits="quiet">{text}</Markdown>
      </div>
      {(long || open) && (
        <button
          type="button"
          className="cv-subsession__toggle"
          aria-expanded={open}
          aria-controls={id}
          onClick={() => setOpen((value) => !value)}
        >
          {t(open ? "message.less" : prompt ? "subsession.showPrompt" : "message.more")}
        </button>
      )}
    </div>
  );
}

/// The call's request and response as the generic MCP row shows them, behind "Raw".
function Raw({ tool, promptFindId }: { tool: Tool; promptFindId?: string }) {
  const [open, setOpen] = useState(false);
  const [reveal, setReveal] = useState(0);
  useFindReveal(
    useMemo(() => [toolActivity(tool)], [tool]),
    () => {
      setOpen(true);
      setReveal((value) => value + 1);
    },
  );
  return (
    <RawToggle open={open} onOpenChange={setOpen}>
      <McpDetails tool={tool} reveal={reveal} promptFindId={promptFindId} />
    </RawToggle>
  );
}

function McpDetails({ tool, reveal = 0, promptFindId }: { tool: Tool; reveal?: number; promptFindId?: string }) {
  const id = useId();
  const call = useMemo(() => mcpCall(tool), [tool]);
  if (!call) return null;
  return (
    <McpCallDetails
      id={id}
      call={call}
      raw={mcpRawName(tool, call)}
      output={tool.output}
      tool={tool}
      strip={false}
      reveal={reveal}
      requestFindAlternatives={promptFindId ? { prompt: promptFindId } : undefined}
    />
  );
}

/// When the receiver reads the message, after the line.
function deliveryText(t: Translate, delivery: SubsessionDelivery): string {
  switch (delivery.kind) {
    case "next_step":
      return t("subsession.delivery.nextStep");
    case "queued":
      return delivery.position !== undefined
        ? t("subsession.delivery.queued", { n: delivery.position })
        : t("subsession.delivery.queuedBare");
    case "started":
      return t("subsession.delivery.started");
    case "slot":
      return t("subsession.delivery.waitingForSlot");
  }
}

/// "Sent message to tests" and the first line, the row a shell `acpmux send` draws too
/// (SentMessageLine.tsx); it opens to the whole message and the call's Raw.
function SentLine({ call, tool }: { call: Extract<SubsessionCall, { tool: "send" }>; tool: Tool }) {
  const t = useT();
  const live = useSubsessionInfo(call.sessionId);
  return (
    <SentMessageLine
      tool={tool}
      state={call.running ? "sending" : "sent"}
      target={live?.name ?? shortId(call.sessionId)}
      text={call.text}
      detail={call.delivery && deliveryText(t, call.delivery)}
      disclosureKey={`send:${tool.id}`}
      targetSession={call.sessionId}
      raw={(reveal) => <McpDetails tool={tool} reveal={reveal} />}
    />
  );
}

/// A wait's or a list's sub-sessions, a card each, a finished one's last reply under its card.
function SessionCards({ call, tool }: { call: Extract<SubsessionCall, { tool: "wait" | "list" }>; tool: Tool }) {
  const t = useT();
  if (call.running)
    return <RunningLine>{t(call.tool === "wait" ? "subsession.waiting" : "subsession.listing")}</RunningLine>;
  if (call.sessions.length === 0)
    return (
      <div className="cv-tool cv-subsession">
        <span className="cv-tool__icon">
          <AgentIdentity harness={undefined} tone={agentTone(tool.id)} size={16} />
        </span>
        <span className="cv-tool__text">{t(call.tool === "wait" ? "subsession.waitNone" : "subsession.listNone")}</span>
      </div>
    );
  return (
    <div className="cv-subsession__cards">
      {call.sessions.map((session) => (
        <SessionCard
          tool={tool}
          key={session.sessionId}
          sessionId={session.sessionId}
          name={session.name ?? shortId(session.sessionId)}
          harness={session.harness}
          fallback={session}
          disclosure
          disclosureKey={`subsession-result:${tool.id}:${session.sessionId}`}
        >
          {session.reply && session.state !== "working" && <CardCopy text={session.reply} />}
          {session.reply && session.state !== "working" && (
            <Cut text={session.reply} disclosureKey={`subsession-reply:${tool.id}:${session.sessionId}`} />
          )}
        </SessionCard>
      ))}
      <Raw tool={tool} />
    </div>
  );
}

/// A session id short enough for a line, for a session the list does not have.
const shortId = (sessionId: string) => (sessionId.length > 12 ? `${sessionId.slice(0, 8)}…` : sessionId);
