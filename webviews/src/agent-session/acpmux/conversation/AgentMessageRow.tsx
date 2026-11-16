// A message between this agent and another one, in either direction, as one collapsed line drawn
// as a tool row is (Claude Code desktop's message rows): the row's icon, the sentence with the
// other agent's name as a chip ("Sent to <release-rings-32>", "Received message from <Grid fix>"),
// then the message's first line, muted and cut with an ellipsis, then the trailing column: the
// status, then the chevron, on the tool rows' grid (`.cv-tool`), so it lines up with theirs. The whole line
// opens the message under it: its full text in a compact glass card, selectable, then what the
// caller adds under the card (a delivery line, Details, a reply editor). It is the one row every
// message between agents draws (Leo, 2026-11-07, on a "Sent to" row, a received one and a "Subagent
// finished" one: "why is it formatted differently from everything else? ... They should look
// basically the same as the other ones"): a send (MessageCard.tsx, SentMessageLine.tsx), a received
// message and an inbox thread (IncomingMessageCard.tsx, InboxNoticeCard.tsx) and a subagent's report
// (subagents/SubagentDoneLine.tsx). Only the verb and the icon say which: "Sent to <name>", the
// sender's name alone after its family mark (named once, cmux#32711), "Subagent finished: <name>". The
// same card, the same Markdown, the same first line that opens in place to the whole message.
// A sender acpmux could not verify gets a small marker (UnverifiedMark.tsx), never words in its
// name. The caller owns whether it is open, so each kind keeps that across the virtualized
// transcript its own way; the line stays on its pixel while the card grows or shrinks under it
// (useAnchoredCollapse.ts), and a caller that wants the fold to play says when (`animates`).
// A row with a `peek` keeps its card shown while shut: the card holds the peek (an inbox thread's
// newest message, whole, InboxNoticeCard.tsx), and opening swaps it for the body in place, the line
// never carrying a first line of its own.
import { useId, useRef, type ReactNode } from "react";
import { ChevronRight } from "./icons";

import { HEADER_TOGGLE_ATTRIBUTE, headerToggleClick } from "./headerToggle";
import { AgentTag } from "./AgentTag";
import { useMessageLineLook } from "./messageLineLook";
import { useMessageRowLook } from "./messageRowLook";
import { UnverifiedMark } from "./UnverifiedMark";
import type { SenderProgram } from "./incomingMessage";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import "./AgentMessageRow.css";
export function AgentMessageRow({
  direction,
  icon,
  sentence,
  name,
  nameTitle,
  onOpenName,
  openNameLabel,
  nameSlot,
  detail,
  unverified = false,
  program,
  claimed,
  preview,
  label,
  open,
  onToggle,
  meta,
  time,
  actions,
  failed = false,
  live = false,
  body,
  under,
  animates,
  className,
  attributes,
  lineClassName,
  lineAttributes,
  previewClassName,
  belowClassName,
  keepsPreviewOpen = false,
  peek,
}: {
  direction: "sent" | "received" | "report";
  /// The row's glyph, in the tool rows' icon column: the envelope for a send, the sender
  /// harness's mark (or a bot) for a received message.
  icon: ReactNode;
  /// The line's words around the name, the name's place marked with U+0000 ("Sent to \0").
  sentence: string;
  /// The other agent, drawn as a chip.
  name: string;
  /// The chip's tooltip: the full id behind a name or a short id.
  nameTitle?: string;
  /// Opens the other agent's chat; without it the chip is plain and opens the message.
  onOpenName?(): void;
  /// The chip's label for a screen reader when it opens a chat.
  openNameLabel?: string;
  /// The name's own control, in place of the chip, when it does more than open a chat (a received
  /// message's sender: its hover card, the machine it runs on; IncomingMessageCard.tsx SenderName).
  nameSlot?: ReactNode;
  /// After the name, before the first line: a thread's `#N`, "+2 more", "· and 1 more command".
  detail?: ReactNode;
  /// acpmux could not verify the other agent (senderIdentity.ts): the subtle marker by its name.
  unverified?: boolean;
  /// The program acpmux saw send it (incomingMessage.ts `senderProgram`): the marker says so.
  program?: SenderProgram;
  /// The name an unverified sender gave itself: the marker says it is only a claim.
  claimed?: string;
  /// The message's first line, shown while closed.
  preview: string;
  /// The toggle's label: the line as a sentence.
  label: string;
  open: boolean;
  onToggle(): void;
  /// The trailing column's status (Sent, Queued, Delivered), before the chevron, as a tool row's meta.
  meta?: ReactNode;
  /// The trailing column's time, after the status ("12m 17s").
  time?: ReactNode;
  /// The hover row (Copy, Reply), outside the toggle, at the sentence column's end.
  actions?: ReactNode;
  failed?: boolean;
  /// A send still going out: the row reads as a running tool row.
  live?: boolean;
  /// The opened message, in the glass card.
  body: ReactNode;
  /// Under the card while open.
  under?: ReactNode;
  /// Whether a toggle plays the fold (default: none, the card opens and closes at once).
  animates?: () => boolean;
  className?: string;
  attributes?: Record<`data-${string}`, string | undefined>;
  /// The line's own classes and attributes, next to the tool row's (a send's `cv-sent`).
  lineClassName?: string;
  lineAttributes?: Record<`data-${string}`, string | undefined>;
  /// The first line's own class, next to `cv-agentmsg__preview`, and the stacked line's under the row.
  previewClassName?: string;
  belowClassName?: string;
  /// Opened, the line keeps its first line, as the disclosure line a received message and an inbox
  /// thread drew before did: the chevron after the words stays on its pixel instead of jumping back
  /// to the chip (gallery health's layout-shift row for agent-pane.inbox-notice#one-open is 0).
  keepsPreviewOpen?: boolean;
  /// Shut, the card shows this instead of closing: the message's text readable without a click
  /// (Leo, 2026-11-09). Open, the card shows `body`. The line then never draws the first line.
  peek?: ReactNode;
}) {
  const bodyId = useId();
  const [before = "", after = ""] = sentence.split("\u0000");
  const rowLook = useMessageRowLook();
  // The line stays where it is drawn while the card opens under it; the caller holds the state.
  const collapse = useAnchoredCollapse({
    open,
    onOpenChange: (next) => next !== open && onToggle(),
    animates: animates ?? never,
    fadeIn: false,
  });
  // A click on the line (its words, its chevron) that closes the message hands focus to the toggle,
  // the line's one control, so focus inside the closing card (a reply's editor) is never dropped.
  const toggleRef = useRef<HTMLButtonElement>(null);
  const closeToToggle = (event?: unknown) => {
    // The click itself, so a drag across the line toggles nothing (useAnchoredCollapse `deliberateClick`).
    if (collapse.toggle(event) && open) toggleRef.current?.focus({ preventScroll: true });
  };
  const marker = unverified && (
    <UnverifiedMark className={rowLook === "corner" ? "is-corner" : undefined} program={program} claimed={claimed} />
  );
  // Single (the default, messageLineLook.ts): the first line on the row, after the name; the
  // stacked gallery version puts it under the row, on its own line.
  const look = useMessageLineLook();
  const shown = peek === undefined && (!open || keepsPreviewOpen);
  const inline = look === "single" && shown ? preview : "";
  const below = look === "stacked" && shown ? preview : "";
  return (
    <div
      className={`cv-agentmsg${failed ? " is-failed" : ""}${className ? ` ${className}` : ""}`}
      data-direction={direction}
      data-look={rowLook}
      data-open={open || undefined}
      {...attributes}
    >
      {/* The tool rows' one grammar (design/chat-transcript.md, "One row grammar"): the icon, the
          sentence (verb, the recipient chip, the muted first line) cut with one ellipsis, then the
          trailing column, status then the chevron, so the chevron sits on the same line whether or
          not the row has a status. */}
      {/* The entire header toggles except its own buttons; preserve the shared selection guard. */}
      {/* oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions */}
      <div
        ref={collapse.headerRef}
        className={`cv-tool cv-agentmsg__line${live ? " is-live" : " is-strong"}${lineClassName ? ` ${lineClassName}` : ""}`}
        {...lineAttributes}
        {...{ [HEADER_TOGGLE_ATTRIBUTE]: "" }}
        onClick={headerToggleClick(closeToToggle)}
      >
        <span className="cv-tool__icon cv-agentmsg__icon">
          {icon}
          {rowLook === "corner" && marker}
        </span>
        <span className="cv-agentmsg__sentence">
          {/* The words toggle too, for the pointer; the toggle button is the control, and its label
              reads the line. */}
          {/* The spaces make the line read as a sentence (its text, Copy, a screen reader); the
              row's flex gap draws the room. */}
          {before.trim() && (
            <span className="cv-agentmsg__words" aria-hidden>
              {before.trim()}
            </span>
          )}
          {before.trim() && " "}
          {nameSlot ?? (
            <AgentTag
              name={name}
              className="cv-agentmsg__name cv-recipient"
              ariaLabel={openNameLabel}
              title={nameTitle}
              onClick={onOpenName}
            />
          )}
          {rowLook !== "corner" && marker}
          {after.trim() && " "}
          {after.trim() && (
            <span className="cv-agentmsg__words" aria-hidden>
              {after.trim()}
            </span>
          )}
          {detail}
          {inline && " "}
          <button
            ref={toggleRef}
            type="button"
            className="cv-agentmsg__toggle"
            aria-expanded={open}
            aria-controls={open || peek !== undefined ? bodyId : undefined}
            aria-label={label}
            onClick={collapse.toggle}
          >
            {/* Open, the message is under the line: its first line here would say it twice, unless
                the row keeps its line as it was (`keepsPreviewOpen`). */}
            {/* A copy of the card's first line: Find counts the card's words, not this. */}
            <span
              className={`cv-agentmsg__preview${previewClassName && inline ? ` ${previewClassName}` : ""}`}
              data-find-skip=""
            >
              {inline}
            </span>
          </button>
          {/* The hover row stays in the sentence column: the trailing column holds only status. */}
          {actions}
        </span>
        {(meta || time) && " "}
        {(meta || time) && (
          <span className="cv-tool__trail">
            {meta}
            {time && <span className="cv-command__meta cv-agentmsg__time">{time}</span>}
          </span>
        )}
        <span className="cv-tool__chevron cv-agentmsg__chevron" aria-hidden>
          <ChevronRight size={14} className={`cv-rotor${open ? " is-open" : ""}`} />
        </span>
      </div>
      {below && (
        // Its words are the toggle's label too, so a screen reader reads them there.
        // oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions
        <div
          className={`cv-msgline__preview cv-agentmsg__below${belowClassName ? ` ${belowClassName}` : ""}`}
          aria-hidden
          // A copy of the card's first line, as the line's preview is: Find counts the card's words.
          data-find-skip=""
          onClick={collapse.toggle}
        >
          {below}
        </div>
      )}
      {peek !== undefined ? (
        // One card in both states: only what it holds changes, under a line that stays put.
        <div className="cv-agentmsg__open">
          <div id={bodyId} className="cv-agentmsg__card selectable">
            {open ? body : peek}
          </div>
          {open && under}
        </div>
      ) : (
        collapse.present && (
          <div {...collapse.bodyProps}>
            <div className="cv-agentmsg__open">
              {/* The body opens whole from the line's own toggle, never cut, so it carries no Show
                  more of its own. TODO(#37610): swap to ExpandRow if a long body gets cut here. */}
              <div id={bodyId} className="cv-agentmsg__card selectable">
                {body}
              </div>
              {under}
            </div>
          </div>
        )
      )}
    </div>
  );
}

const never = () => false;
