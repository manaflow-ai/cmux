// A message between this agent and another one, in either direction, as one collapsed line drawn
// as a tool row is (Claude Code desktop's message rows): the row's icon, the sentence with the
// other agent's name as a chip ("Sent to <release-rings-32>", "Received message from <Grid fix>"),
// then the message's first line, muted and cut with an ellipsis, then the trailing column: the
// status, then the chevron, on the tool rows' grid (`.cv-tool`), so it lines up with theirs. The whole line
// opens the message under it: its full text in a compact glass card, selectable, then what the
// caller adds under the card (a delivery line, Details, a reply editor). MessageCard.tsx draws an
// outgoing message with it; IncomingMessageCard.tsx's line is the incoming one. The caller owns
// whether it is open, so each direction keeps that across the virtualized transcript its own way.
import { useId, type ReactNode } from "react";
import { ChevronRight } from "./icons";
import { clipMessagePreview } from "./clipMessagePreview";
import { HEADER_TOGGLE_ATTRIBUTE, headerToggleClick } from "./headerToggle";
import { AgentTag } from "./AgentTag";
import "./AgentMessageRow.css";

/// The message's first line of text as it reads, its spaces collapsed and its Markdown marks (a
/// heading's or quote's or list item's lead, emphasis, code ticks) dropped: the closed line's
/// preview. The same reading as incomingMessage.ts gives a received message (#23727).
export function messagePreview(text: string): string {
  const line = text.split("\n").find((part) => part.trim()) ?? "";
  return clipMessagePreview(
    line.replace(/^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?)/, "").replace(/(\*\*|__|`)/g, ""),
  );
}

export function AgentMessageRow({
  direction,
  icon,
  sentence,
  name,
  nameTitle,
  onOpenName,
  openNameLabel,
  preview,
  label,
  open,
  onToggle,
  meta,
  actions,
  failed = false,
  live = false,
  body,
  under,
  className,
  attributes,
}: {
  direction: "sent" | "received";
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
  /// The message's first line, shown while closed.
  preview: string;
  /// The toggle's label: the line as a sentence.
  label: string;
  open: boolean;
  onToggle(): void;
  /// The trailing column's status (Sent, Queued, Delivered), before the chevron, as a tool row's meta.
  meta?: ReactNode;
  /// The hover row (Copy, Reply), outside the toggle, at the sentence column's end.
  actions?: ReactNode;
  failed?: boolean;
  /// A send still going out: the row reads as a running tool row.
  live?: boolean;
  /// The opened message, in the glass card.
  body: ReactNode;
  /// Under the card while open.
  under?: ReactNode;
  className?: string;
  attributes?: Record<`data-${string}`, string | undefined>;
}) {
  const bodyId = useId();
  const [before = "", after = ""] = sentence.split("\u0000");
  return (
    <div
      className={`cv-agentmsg${failed ? " is-failed" : ""}${className ? ` ${className}` : ""}`}
      data-direction={direction}
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
        className={`cv-tool cv-agentmsg__line${live ? " is-live" : " is-strong"}`}
        {...{ [HEADER_TOGGLE_ATTRIBUTE]: "" }}
        onClick={headerToggleClick(onToggle)}
      >
        <span className="cv-tool__icon cv-agentmsg__icon">{icon}</span>
        <span className="cv-agentmsg__sentence">
          {/* The words toggle too, for the pointer; the toggle button is the control, and its label
              reads the line. */}
          {before.trim() && (
            <span className="cv-agentmsg__words" aria-hidden>
              {before.trim()}
            </span>
          )}
          <AgentTag
            name={name}
            className="cv-agentmsg__name cv-recipient"
            ariaLabel={openNameLabel}
            title={nameTitle}
            onClick={onOpenName}
          />
          {after.trim() && (
            <span className="cv-agentmsg__words" aria-hidden>
              {after.trim()}
            </span>
          )}
          <button
            type="button"
            className="cv-agentmsg__toggle"
            aria-expanded={open}
            aria-controls={open ? bodyId : undefined}
            aria-label={label}
            onClick={onToggle}
          >
            {/* Open, the message is under the line: its first line here would say it twice. */}
            <span className="cv-agentmsg__preview">{open ? "" : preview}</span>
          </button>
          {/* The hover row stays in the sentence column: the trailing column holds only status. */}
          {actions}
        </span>
        {meta && <span className="cv-tool__trail">{meta}</span>}
        <span className="cv-tool__chevron cv-agentmsg__chevron" aria-hidden>
          <ChevronRight size={14} strokeWidth={1.2} className={`cv-rotor${open ? " is-open" : ""}`} />
        </span>
      </div>
      {open && (
        <div id={bodyId} className="cv-agentmsg__card selectable">
          {body}
        </div>
      )}
      {open && under}
    </div>
  );
}
