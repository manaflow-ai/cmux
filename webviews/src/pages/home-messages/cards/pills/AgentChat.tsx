// One agent's chat in the agent pane, the tab a pill opens (Swift `HomeAgentChatView`, user
// 2026-11-03 and plans/cmux-next/home-agent-pills-DESIGN.md): a header with the agent's title,
// status and Go to workspace; "Sent via Chief" over the task (Show more); "Worked for 5m 35s ›"
// over when it started and ended; then every later message, each one to the agent labelled "You"
// or "Chief"; then the composer the person shares with the Chief (what they send goes to the
// agent through the Chief, which sees it). Message text draws with the agent pane's Markdown.
// `compact` is the peek's look: no composer, the task in two lines, the newest reply only.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Markdown } from "../../../../agent-session/acpmux/conversation/Markdown";
import { Icon } from "../../../../agent-session/acpmux/icons/Icon";
import type { Strings } from "../strings";
import type { AgentChatContent } from "./agentModel";
import "../cards.css";

export interface AgentChatActions {
  goToWorkspace?(): void;
  /** The peek's Open: the chat moves to the right pane. */
  open?(): void;
  /** The pushed chat's back button. */
  back?(): void;
  /** The peek's close button. */
  close?(): void;
  /** A message the person sent from the composer; absent: no composer. */
  sent?(text: string): void;
}

/** How many of the person's own messages say `text`. */
function yours(messages: AgentChatContent["messages"], text: string): number {
  return messages.filter((message) => message.sender === "you" && message.text === text).length;
}

export interface AgentChatProps {
  content: AgentChatContent;
  compact?: boolean;
  strings: Strings;
  actions: AgentChatActions;
}

export function AgentChat({ content, compact = false, strings, actions }: AgentChatProps) {
  const { t } = strings;
  const [taskOpen, setTaskOpen] = useState(false);
  const [stepsOpen, setStepsOpen] = useState(false);
  const [draft, setDraft] = useState("");
  // What the person sent shows at once and stays until the store's content carries it (a refresh
  // before the echo keeps it). `before` counts the person's messages with that text when it was
  // sent, so an earlier message with the same words is not taken for its echo.
  const [sent, setSent] = useState<{ text: string; before: number }[]>([]);
  const scroller = useRef<HTMLDivElement>(null);
  const follow = useRef(false);
  useEffect(() => setSent([]), [content.peer]);
  const pending = sent.filter(({ text, before }) => yours(content.messages, text) <= before);
  useLayoutEffect(() => {
    if (!follow.current || !scroller.current) return;
    follow.current = false;
    scroller.current.scrollTop = scroller.current.scrollHeight;
  });
  const messages = [...content.messages, ...pending.map(({ text }) => ({ sender: "you" as const, text }))];
  const shown = compact ? messages.slice(-1) : messages;
  const send = () => {
    const text = draft.trim();
    if (!text || !actions.sent) return;
    setDraft("");
    setSent((list) => [...list, { text, before: yours(content.messages, text) }]);
    follow.current = true;
    actions.sent(text);
  };
  // Where it runs once it moved (a machine name, not words): "a12 · Working · cmux-mini".
  const status = [content.peer, content.status, content.place].filter(Boolean).join(" · ");
  return (
    <section className="hm-agent-chat" data-compact={compact ? "" : undefined} aria-label={content.title}>
      <header className="hm-agent-chat__header">
        {actions.back && (
          <button type="button" className="hm-agent-chat__button" onClick={actions.back}>
            <Icon name="nav.back" size={14} />
            {t("home.agentPane.sender.chief")}
          </button>
        )}
        <span className="hm-agent-chat__names">
          <span className="hm-agent-chat__title">{content.title}</span>
          <span className="hm-agent-chat__status">{status}</span>
        </span>
        {actions.goToWorkspace && content.workspaceLink && (
          <button
            type="button"
            className="hm-agent-chat__button"
            data-testid="home.agentPane.goToWorkspace"
            onClick={actions.goToWorkspace}
          >
            <Icon name="link.external" size={14} />
            {t("home.agentPane.goToWorkspace")}
          </button>
        )}
        {actions.open && (
          <button type="button" className="hm-agent-chat__button" onClick={actions.open}>
            <Icon name="panel.right" size={14} />
            {t("home.agentPane.open")}
          </button>
        )}
        {actions.close && (
          <button type="button" className="hm-agent-chat__button" onClick={actions.close}>
            <Icon name="action.close" size={14} />
            {t("home.agentPane.close")}
          </button>
        )}
      </header>
      <div className="hm-agent-chat__scroll" ref={scroller}>
        {content.task && (
          <div className="hm-agent-chat__out">
            <span className="hm-agent-chat__sender">{t("home.agentPane.sentViaChief")}</span>
            <div className="hm-agent-chat__bubble" data-clamp={taskOpen ? undefined : compact ? 2 : 4}>
              {content.task}
            </div>
            <button type="button" className="hm-agent-chat__link" onClick={() => setTaskOpen(!taskOpen)}>
              {t(taskOpen ? "home.agentPane.showLess" : "home.agentPane.showMore")}
            </button>
          </div>
        )}
        {content.workedFor && (
          <div className="hm-agent-chat__steps">
            <button
              type="button"
              className="hm-agent-chat__link hm-agent-chat__link--quiet"
              aria-expanded={compact || !content.details.length ? undefined : stepsOpen}
              onClick={() => setStepsOpen(!stepsOpen)}
            >
              {`${content.workedFor} ›`}
            </button>
            {!compact && stepsOpen && content.details.length > 0 && (
              <ul className="hm-agent-chat__details">
                {content.details.map((line) => (
                  <li key={line}>{line}</li>
                ))}
              </ul>
            )}
          </div>
        )}
        {shown.map((message, index) =>
          message.sender === "agent" ? (
            <div key={index} className="hm-agent-chat__in">
              <Markdown>{message.text}</Markdown>
            </div>
          ) : (
            // A message the Chief (or the person) sent the agent: its sender over a bubble on the right.
            <div key={index} className="hm-agent-chat__out" data-sender={message.sender}>
              <span className="hm-agent-chat__sender">{t(`home.agentPane.sender.${message.sender}`)}</span>
              <div className="hm-agent-chat__bubble">{message.text}</div>
            </div>
          ),
        )}
      </div>
      {!compact && actions.sent && (
        <form
          className="hm-agent-chat__composer"
          onSubmit={(event) => {
            event.preventDefault();
            send();
          }}
        >
          <input
            className="hm-agent-chat__field"
            data-testid="home.agentPane.composer"
            placeholder={strings.format("home.agentPane.composer.placeholder", content.peer)}
            aria-label={strings.format("home.agentPane.composer.placeholder", content.peer)}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
          />
          <button type="submit" className="hm-agent-chat__send" aria-label={t("home.agentPane.composer.send")}>
            <Icon name="composer.send" size={16} />
          </button>
        </form>
      )}
    </section>
  );
}
