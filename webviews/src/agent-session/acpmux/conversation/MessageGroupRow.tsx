// Two or more messages to other agents in a row (toolGroups.ts `messages`), as Claude desktop
// draws a run of SendMessage calls (Leo 2026-10-29: "this would be decent ui for cmux-next... tho i
// dont mind what we have now. i just think we can do a little bit better"). One line sums them up:
// while one still goes out, the present tense with its target and the time since the first left
// ("Messaging tests 11s"); once all went, the past tense with a count ("Messaged tests 3 times",
// "Messaged 3 agents"). Under it, one quiet bordered card with a row per message, the rows each
// message draws on its own (MessageCard.tsx, SentMessageLine.tsx), split by hairlines; a row opens
// in place to its whole message as text, with Copy under the pointer.
//
// The group starts open while a message goes out and closed once all went; the reader's choice
// lasts across the virtualized transcript (transcriptDisclosure.tsx). Opening and closing take
// effect on the click, with no fold animation (`animates`), and the line stays where it was.
//
// The clock: `useNow` ticks once a second only while a message goes out and the pane shows; it
// stops when the last one went, when the pane hides, and when the row unmounts.
import { useContext, useId, useMemo, type ReactNode } from "react";
import { useT, type Translate } from "../i18n";
import { useSubsessionInfos } from "../subagents/subsessions";
import { useNow } from "../subagents/SubagentGroup";
import { AgentNamesContext, recipientName, shortId } from "./agentNames";
import { useFindReveal } from "./chatFind";
import { ChevronRight, Envelope, Spinner } from "./icons";
import { useMessageGroupLook } from "./messageGroupLook";
import { sendKey } from "./SentMessageLine";
import { leadingVerb, ToolLabel } from "./ToolVerb";
import { isRunning, type MessageEntry } from "./toolGroups";
import { formatDuration } from "./turns";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import "./MessageGroupRow.css";

/// Where the target sits in the translated line, so it can take its own tone.
const MARK = "\u0001";
const instant = () => false;

/// Whether a member still goes out.
export function memberSending(member: MessageEntry): boolean {
  switch (member.type) {
    case "send":
      return member.send.state === "sending";
    case "subsession":
      return member.call.running;
    case "message":
      return isRunning(member.item.tool!);
  }
}

/// A member's React key: its call's id, and for one message of a batch its place in the batch.
function memberKey(member: MessageEntry): string {
  const id = member.item.tool!.id;
  return member.type === "send" ? sendKey(id, member.send.index) : id;
}

/// The member's target as its own row names it; `session` is a sub-session's listed name.
function memberTarget(
  t: Translate,
  member: MessageEntry,
  names: ReadonlyMap<string, string>,
  session: string | undefined,
): string {
  switch (member.type) {
    case "send":
      return member.send.target;
    case "subsession":
      return session ?? shortId(member.call.sessionId);
    case "message": {
      const to = member.message.to;
      return to ? (recipientName(to, names) ?? shortId(to)) : t("message.unknown");
    }
  }
}

/// The group's line: the sentence around its target, the target, and the running time.
export function messageGroupLine(
  t: Translate,
  targets: readonly string[],
  sending: readonly boolean[],
): { before: string; target?: string; after: string } {
  const live = sending.lastIndexOf(true);
  const split = (text: string, target?: string) => {
    const [before = "", after = ""] = text.split(MARK);
    return { before, after, ...(target !== undefined && { target }) };
  };
  if (live >= 0) return split(t("messages.group.sending", { target: MARK }), targets[live]);
  const first = targets[0] ?? "";
  if (targets.every((target) => target === first))
    return split(t("messages.group.sentTo", { target: MARK, n: targets.length }), first);
  return split(t("messages.group.sent", { n: new Set(targets).size }));
}

/// The line's words with its verb in the turn's verb column (ToolVerb.tsx), as a tool group's is:
/// "Messaged" over "Ran" and "Read", the target after it in the text colour.
function GroupLabel({ line }: { line: ReturnType<typeof messageGroupLine> }) {
  if (line.target === undefined) return <ToolLabel text={`${line.before}${line.after}`} />;
  const subject = (
    <>
      <span className="cv-msggroup__target">{line.target}</span>
      {line.after}
    </>
  );
  const verb = leadingVerb(line.before);
  // Outside a column (or where the verb does not lead) the words draw as they are.
  return (
    <ToolLabel verb={verb} subject={subject}>
      {line.before}
      {subject}
    </ToolLabel>
  );
}

export function MessageGroupRow({
  members,
  disclosureKey,
  children,
}: {
  members: readonly MessageEntry[];
  disclosureKey: string;
  /// Each member's own row, in order (TurnRows.tsx `groupNode`).
  children: readonly ReactNode[];
}) {
  const t = useT();
  const look = useMessageGroupLook();
  const names = useContext(AgentNamesContext);
  const sessionIds = useMemo(
    () => members.map((member) => (member.type === "subsession" ? member.call.sessionId : undefined)),
    [members],
  );
  const sessions = useSubsessionInfos(sessionIds);
  const sending = members.map(memberSending);
  const running = sending.includes(true);
  const targets = members.map((member, at) => memberTarget(t, member, names, sessions[at]?.name));
  const line = messageGroupLine(t, targets, sending);
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey, running);
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen, animates: instant });
  useFindReveal(
    useMemo(() => members.map((member) => member.item), [members]),
    () => setOpen(true),
  );
  // From the first message out to now; the clock rests once all went (`useNow`).
  const now = useNow(running);
  const started = members.find((member) => member.item.tool!.startedAt !== undefined)?.item.tool!.startedAt;
  const elapsed = running && started !== undefined ? formatDuration(Math.max(0, now - started)) : undefined;
  const bodyId = useId();
  const label = [line.before, line.target, line.after].join("").replace(/\s+/g, " ").trim();
  const entries = children.map((child, at) => (
    <div key={memberKey(members[at]!) || at} className="cv-msggroup__entry">
      {child}
    </div>
  ));
  // The gallery's "before": each message its own row, as they drew before groups.
  if (look === "off") return <>{children}</>;
  const card =
    look === "guide"
      ? "cv-tool-group cv-msggroup__guide"
      : look === "list"
        ? "cv-msggroup__card is-list"
        : "cv-msggroup__card";
  return (
    <div className="cv-msggroup" data-look={look} data-running={running || undefined} data-open={open || undefined}>
      <button
        type="button"
        className={`cv-tool is-toggle cv-msggroup__line${running ? " is-live" : " is-strong"}`}
        aria-expanded={open}
        aria-controls={open ? bodyId : undefined}
        aria-label={elapsed ? `${label} ${elapsed}` : label}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        <span className="cv-tool__icon">{running ? <Spinner size={16} /> : <Envelope />}</span>
        <span className="cv-tool__text" data-find-skip>
          <GroupLabel line={line} />
          {elapsed && <span className="cv-msggroup__time">{elapsed}</span>}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {fold.present && (
        <div {...fold.bodyProps}>
          <div className={card} id={bodyId}>
            {entries}
          </div>
        </div>
      )}
    </div>
  );
}
