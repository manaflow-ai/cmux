// A message between this agent and another one, in either direction, as one collapsed line drawn
// as a tool row is (Claude Code desktop's message rows): the row's icon, the sentence with the
// other agent's name as a chip ("Sent to <release-rings-32>", "Received message from <Grid fix>"),
// then the message's first line, muted and cut with an ellipsis, and the chevron. The whole line
// opens the message under it: its full text in a compact glass card, selectable, then what the
// caller adds under the card (a delivery line, Details, a reply editor). MessageCard.tsx draws an
// outgoing message with it; IncomingMessageCard.tsx's line is the incoming one. The caller owns
// whether it is open, so each direction keeps that across the virtualized transcript its own way.
import { useId, type ReactNode, type Ref, type MouseEvent } from "react";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { ChevronRight } from "./icons";
import "./AgentMessageRow.css";

/// The message's first line of text as it reads, its spaces collapsed and its Markdown marks (a
/// heading's or quote's or list item's lead, emphasis, code ticks) dropped: the closed line's
/// preview. The same reading as incomingMessage.ts gives a received message (#23727).
export function messagePreview(text: string): string {
  const line = text.split("\n").find((part) => part.trim()) ?? "";
  return line
    .replace(/^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?)/, "")
    .replace(/(\*\*|__|`)/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 240);
}

// Both directions keep nested actions independent of the row's pointer disclosure.
export function toggleAgentMessageLine(event: MouseEvent<HTMLElement>, toggle: () => void): void {
  if ((event.target as Element).closest("button, a, input, textarea, select, summary, [role=button]")) return;
  if (event.currentTarget.ownerDocument.getSelection()?.isCollapsed === false) return;
  toggle();
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
  toggleRef,
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
  /// Keeps focus on the disclosure after a nested action closes (received rows).
  toggleRef?: Ref<HTMLButtonElement>;
  /// At the line's right edge (a finished send's check), as a tool row's meta.
  meta?: ReactNode;
  /// The line's end, after the meta and outside the toggle: Reply, the message's hover row.
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
  const collapse = useAnchoredCollapse({ open, onOpenChange: onToggle, fadeIn: false });
  const [before = "", after = ""] = sentence.split("\u0000");
  return (
    <div
      className={`cv-agentmsg${failed ? " is-failed" : ""}${className ? ` ${className}` : ""}`}
      data-direction={direction}
      data-open={open || undefined}
      {...attributes}
    >
      {/* The disclosure button is the keyboard control; the wrapper extends its pointer hit area. */}
      <div
        role="presentation"
        className={`cv-tool cv-agentmsg__line${direction === "received" ? " cv-received__line" : ""}${live ? " is-live" : " is-strong"}`}
        onClick={(event) => toggleAgentMessageLine(event, collapse.toggle)}
      >
        <span className={`cv-tool__icon cv-agentmsg__icon${direction === "received" ? " cv-received__icon" : ""}`}>
          {icon}
        </span>
        {/* The words toggle too, for the pointer; the toggle button is the control, and its label
            reads the line. */}
        {before.trim() && (
          <span className="cv-agentmsg__words" aria-hidden>
            {before.trim()}
          </span>
        )}
        {onOpenName ? (
          <button
            type="button"
            className={`cv-agentmsg__name${direction === "received" ? " cv-received__name" : ""}`}
            aria-label={openNameLabel}
            title={nameTitle}
            onClick={onOpenName}
          >
            {name}
          </button>
        ) : (
          <span
            className={`cv-agentmsg__name is-plain${direction === "received" ? " cv-received__name" : ""}`}
            aria-hidden
            title={nameTitle}
          >
            {name}
          </span>
        )}
        {after.trim() && (
          <span className="cv-agentmsg__words" aria-hidden>
            {after.trim()}
          </span>
        )}
        <button
          ref={(node) => {
            collapse.headerRef(node);
            if (typeof toggleRef === "function") toggleRef(node);
            else if (toggleRef) toggleRef.current = node;
          }}
          type="button"
          className={`cv-agentmsg__toggle${direction === "received" ? " cv-received__toggle" : ""}`}
          aria-expanded={open}
          aria-controls={open ? bodyId : undefined}
          aria-label={label}
          onClick={(event) => {
            event.stopPropagation();
            collapse.toggle();
          }}
        >
          {!open && (
            <span className={`cv-agentmsg__preview${direction === "received" ? " cv-received__preview" : ""}`}>
              {preview}
            </span>
          )}
          <ChevronRight size={14} strokeWidth={1.2} className={`cv-tool__chevron cv-rotor${open ? " is-open" : ""}`} />
        </button>
        {meta}
        {actions}
      </div>
      {collapse.present && (
        <div {...collapse.bodyProps}>
          <div id={bodyId} className="cv-agentmsg__card selectable">
            {body}
          </div>
          {under}
        </div>
      )}
    </div>
  );
}
