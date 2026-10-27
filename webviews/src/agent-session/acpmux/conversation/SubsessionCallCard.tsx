// A call to the cmux-subsessions tools (subsessionCalls.ts) as the sub-sessions it touched, never
// its JSON: a start as the sub-session's card (subagents/AgentCard.tsx) over its prompt as Markdown
// cut to three lines; a wait or a list as each one's card, a finished one's reply under it; a
// message as "Sent message to tests" and its first line (SentMessageLine.tsx, the row a shell
// `acpmux send` draws too), which opens to all of it. Each card reads its state live from
// the session list (subagents/subsessions.ts). The call's JSON stays behind "Raw".
import type { ReactNode } from "react";
import { useContext, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { type Translate, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxActivity } from "../model";
import { AgentCard } from "../subagents/AgentCard";
import { SubsessionContext, useSenderChat, useSubsessionInfo, waitingLine } from "../subagents/subsessions";
import { retryLabel, sessionRetry } from "../subagents/retryState";
import { Spinner } from "./icons";
import { Markdown } from "./Markdown";
import { McpCallDetails } from "./McpCallRows";
import { mcpCall, mcpRawName } from "./mcpCalls";
import { RawToggle, SentMessageLine } from "./SentMessageLine";
import type { SubsessionCall, SubsessionDelivery, SubsessionReply } from "./subsessionCalls";
import "./SubsessionCallCard.css";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export function SubsessionCallCard({ call, tool }: { call: SubsessionCall; tool: Tool }) {
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

/// The live card of sub-session `sessionId`, with what the call knew of it until the list has it.
function SessionCard({
  sessionId,
  name,
  harness,
  model,
  fallback,
  children,
}: {
  sessionId?: string;
  name: string;
  harness?: string;
  model?: string;
  /// Its state as the call read it, for a session the list does not have.
  fallback?: Pick<SubsessionReply, "state" | "waiting" | "slot">;
  children?: ReactNode;
}) {
  const t = useT();
  const live = useSubsessionInfo(sessionId);
  const listed = useSenderChat("", sessionId).harness;
  const open = useContext(SubsessionContext)?.open;
  // The card's retry, as every surface reads it (retryState.ts ``sessionRetry``): while acpmux
  // retries its failed turn, the card works, and its state says so. Its Retry is on its end line.
  const phase = live ? sessionRetry(live) : undefined;
  const retry = phase?.kind === "retrying" ? phase.retry : undefined;
  const state = retry ? "working" : (live?.state ?? fallback?.state);
  const waiting = live ? live.waiting : fallback?.waiting;
  // A failed one says why (acpmux's lane error), a retry acpmux refused included.
  const doing = waiting ? waitingLine(t, waiting) : (live?.doing ?? (state === "failed" ? live?.error : undefined));
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
      onOpen={sessionId && open ? (event) => open(sessionId, event) : undefined}
    >
      {children}
    </AgentCard>
  );
}

function StartedCard({ call, tool }: { call: Extract<SubsessionCall, { tool: "start" }>; tool: Tool }) {
  const t = useT();
  if (call.running && !call.prompt)
    return (
      <RunningLine>
        {call.name ? t("subsession.starting", { name: call.name }) : t("subsession.startingBare")}
      </RunningLine>
    );
  return (
    <SessionCard
      sessionId={call.sessionId}
      name={call.name ?? (call.sessionId ? shortId(call.sessionId) : t("subsession.startingBare"))}
      harness={call.harness}
      model={call.model}
      // Until the call returns, the sub-session is starting: the working spinner.
      fallback={call.running ? { state: "working" } : undefined}
    >
      {call.prompt && <Cut text={call.prompt} prompt />}
      <Raw tool={tool} />
    </SessionCard>
  );
}

/// Markdown cut to its first three lines, with a toggle to show the rest when there is more (a
/// prompt's "Show prompt"). Whether there is more is measured: the pane's width decides the wrap,
/// so a resize can bring the toggle in or take it away (one observer per cut, gone with it).
export function Cut({ text, prompt }: { text: string; prompt?: boolean }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [long, setLong] = useState(false);
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
function Raw({ tool }: { tool: Tool }) {
  return (
    <RawToggle>
      <McpDetails tool={tool} />
    </RawToggle>
  );
}

function McpDetails({ tool, reveal = 0 }: { tool: Tool; reveal?: number }) {
  const id = useId();
  const call = useMemo(() => mcpCall(tool), [tool]);
  if (!call) return null;
  return (
    <McpCallDetails
      id={id}
      call={call}
      raw={mcpRawName(tool, call)}
      output={tool.output}
      strip={false}
      reveal={reveal}
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
          <Icon name="agent.session" size={16} />
        </span>
        <span className="cv-tool__text">{t(call.tool === "wait" ? "subsession.waitNone" : "subsession.listNone")}</span>
      </div>
    );
  return (
    <div className="cv-subsession__cards">
      {call.sessions.map((session) => (
        <SessionCard
          key={session.sessionId}
          sessionId={session.sessionId}
          name={session.name ?? shortId(session.sessionId)}
          harness={session.harness}
          fallback={session}
        >
          {session.reply && session.state !== "working" && <Cut text={session.reply} />}
        </SessionCard>
      ))}
      <Raw tool={tool} />
    </div>
  );
}

/// A session id short enough for a line, for a session the list does not have.
const shortId = (sessionId: string) => (sessionId.length > 12 ? `${sessionId.slice(0, 8)}…` : sessionId);
