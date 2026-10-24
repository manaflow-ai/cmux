// A call to the cmux-subsessions tools (subsessionCalls.ts) as what it did to which sub-session,
// drawn as tool rows are, in their font, height and rhythm, with nothing on hover:
// "Started sub-session tests · Working · 2 queued" with what its turn does now under it, live
// from the session list (subagents/subsessions.ts); "Sent to tests: <first line> · read at its next
// step"; and for a wait, "Reply from tests" over the reply's first lines, or the sub-session's
// state while it still runs. A sub-session waiting on the person says what for: a question (its
// first prompt after) or a permission, which only the person answers, in its chat. Its name opens its chat beside this one without taking
// focus (`chat.offer.open`). A call still running is one line with the working spinner.
import type { ReactNode } from "react";
import { useContext } from "react";
import { type Translate, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import {
  SUBSESSION_STATE_LABEL,
  SubsessionContext,
  type SubsessionState,
  useSubsessionInfo,
  waitingLine,
} from "../subagents/subsessions";
import type { SessionWaiting } from "../sessionList";
import { Envelope, Spinner } from "./icons";
import type { SubsessionCall, SubsessionDelivery, SubsessionReply } from "./subsessionCalls";
import "./SubsessionCallCard.css";
import { ToolText } from "./ToolText";

export function SubsessionCallCard({ call }: { call: SubsessionCall }) {
  switch (call.tool) {
    case "start":
      return <StartedLine call={call} />;
    case "send":
      return <SentLine call={call} />;
    case "wait":
      return <WaitLines call={call} />;
  }
}

/// Stands in for the name in a translated line, so the name can be drawn as its link.
const NAME = "\u2063name\u2063";

/// `line` (translated with `{name}` as ``NAME``) with the name drawn as `node`.
function withName(line: string, node: ReactNode): ReactNode {
  const at = line.indexOf(NAME);
  if (at < 0) return line;
  return (
    <>
      {line.slice(0, at)}
      {node}
      {line.slice(at + NAME.length)}
    </>
  );
}

/// A sub-session's name: a link that opens its chat beside this one when the pane can open it.
function SessionName({ sessionId, name }: { sessionId?: string; name: string }) {
  const t = useT();
  const open = useContext(SubsessionContext)?.open;
  if (!sessionId || !open) return <span className="cv-subsession__name">{name}</span>;
  return (
    <button
      type="button"
      className="cv-subsession__name is-link"
      aria-label={t("subagents.open", { name })}
      onClick={() => open(sessionId)}
    >
      {name}
    </button>
  );
}

/// What a sub-session's state reads as after its name: its state, and how many messages wait.
function StateDetail({ state, queued }: { state: SubsessionState; queued?: number }) {
  const t = useT();
  return (
    <span className="cv-tool__detail cv-subsession__state" data-state={state}>
      {" · "}
      {t(SUBSESSION_STATE_LABEL[state])}
      {queued ? ` · ${t("subsession.queued", { n: queued })}` : ""}
    </span>
  );
}

function StartedLine({ call }: { call: Extract<SubsessionCall, { tool: "start" }> }) {
  const t = useT();
  const live = useSubsessionInfo(call.sessionId);
  const name = live?.name ?? call.name;
  if (call.running)
    return (
      <div className="cv-tool cv-subsession is-live">
        <span className="cv-tool__icon">
          <Spinner size={16} />
        </span>
        <ToolText working>{name ? t("subsession.starting", { name }) : t("subsession.startingBare")}</ToolText>
      </div>
    );
  return (
    <>
      <div className="cv-tool cv-subsession is-strong" data-state={live?.state}>
        <span className="cv-tool__icon">
          {live?.state === "working" ? <Spinner size={16} /> : <Icon name="agent.session" size={16} />}
        </span>
        <ToolText working={live?.state === "working"}>
          {withName(
            t("subsession.started", { name: NAME }),
            <SessionName sessionId={call.sessionId} name={name ?? call.sessionId!} />,
          )}
          {live && <StateDetail state={live.state} queued={live.queued} />}
        </ToolText>
      </div>
      <UnderLine doing={live?.doing} waiting={live?.waiting} />
    </>
  );
}

/// The line under a sub-session's row: what its turn does now, or what it waits on the person for
/// (a question or a permission, answered in its chat, which its name opens).
function UnderLine({ doing, waiting }: { doing?: string; waiting?: SessionWaiting }) {
  const t = useT();
  const line = waiting ? waitingLine(t, waiting) : doing;
  if (!line) return null;
  return (
    <div className="cv-subsession__under cv-subsession__doing" data-waiting={waiting ? waiting.on : undefined}>
      {line}
    </div>
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
  }
}

function SentLine({ call }: { call: Extract<SubsessionCall, { tool: "send" }> }) {
  const t = useT();
  const live = useSubsessionInfo(call.sessionId);
  const name = live?.name ?? shortId(call.sessionId);
  const first = firstLine(call.text);
  return (
    <div className={`cv-tool cv-subsession${call.running ? " is-live" : " is-strong"}`}>
      <span className="cv-tool__icon">{call.running ? <Spinner size={16} /> : <Envelope />}</span>
      <ToolText working={call.running}>
        {withName(
          t(call.running ? "subsession.sending" : "subsession.sent", { name: NAME, text: first }),
          <SessionName sessionId={call.sessionId} name={name} />,
        )}
        {call.delivery && <span className="cv-tool__detail">{` · ${deliveryText(t, call.delivery)}`}</span>}
      </ToolText>
    </div>
  );
}

function WaitLines({ call }: { call: Extract<SubsessionCall, { tool: "wait" }> }) {
  const t = useT();
  if (call.running)
    return (
      <div className="cv-tool cv-subsession is-live">
        <span className="cv-tool__icon">
          <Spinner size={16} />
        </span>
        <ToolText working>{t("subsession.waiting")}</ToolText>
      </div>
    );
  if (call.sessions.length === 0)
    return (
      <div className="cv-tool cv-subsession">
        <span className="cv-tool__icon">
          <Icon name="agent.session" size={16} />
        </span>
        <span className="cv-tool__text">{t("subsession.waitNone")}</span>
      </div>
    );
  return (
    <>
      {call.sessions.map((session) => (
        <ReplyLine key={session.sessionId} session={session} />
      ))}
    </>
  );
}

/// One sub-session a wait read: its reply once it finished, else its state then ("Still running").
function ReplyLine({ session }: { session: SubsessionReply }) {
  const t = useT();
  const live = useSubsessionInfo(session.sessionId);
  const name = live?.name ?? session.name ?? shortId(session.sessionId);
  const link = <SessionName sessionId={session.sessionId} name={name} />;
  const replied = session.state === "done" || (session.state === "failed" && session.reply);
  return (
    <>
      <div className={`cv-tool cv-subsession${replied ? " is-strong" : ""}`} data-state={session.state}>
        <span className="cv-tool__icon">
          <Icon name="agent.session" size={16} />
        </span>
        <span className="cv-tool__text">
          {replied ? withName(t("subsession.reply", { name: NAME }), link) : link}
          {session.state === "working" ? (
            <span className="cv-tool__detail">{` · ${t("subsession.stillRunning")}`}</span>
          ) : (
            session.state !== "done" && <StateDetail state={session.state} />
          )}
        </span>
      </div>
      {replied && session.reply && (
        <div className="cv-subsession__under cv-subsession__reply selectable">{session.reply}</div>
      )}
      {session.state === "input" && <UnderLine waiting={session.waiting} />}
    </>
  );
}

/// A message's first line that says something.
function firstLine(text: string): string {
  return (
    text
      .split("\n")
      .map((line) => line.trim())
      .find(Boolean) ?? ""
  );
}

/// A session id short enough for a line, for a session the list does not have.
const shortId = (sessionId: string) => (sessionId.length > 12 ? `${sessionId.slice(0, 8)}…` : sessionId);
