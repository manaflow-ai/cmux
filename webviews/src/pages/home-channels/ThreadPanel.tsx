// The thread side panel: the root message, its replies and a reply composer. Escape closes it.
import { useMemo } from "react";
import type { Strings } from "../shared/i18n";
import { Composer } from "./Composer";
import { threadMessages, type TimelineRow } from "./model";
import { Timeline } from "./Timeline";
import type { HomeMessage, HomeParticipant } from "./types";

export interface ThreadPanelProps {
  root: string;
  messages: readonly HomeMessage[];
  people: ReadonlyMap<string, HomeParticipant>;
  me?: string;
  strings: Strings;
  canSend: boolean;
  onClose(): void;
  onSend(text: string): Promise<boolean>;
  onReact(message: HomeMessage, value: string): void;
  onEdit?(message: HomeMessage, text: string): Promise<boolean>;
  onRetract?(message: HomeMessage): void;
}

export function ThreadPanel({
  root,
  messages,
  people,
  me,
  strings,
  canSend,
  onClose,
  onSend,
  onReact,
  onEdit,
  onRetract,
}: ThreadPanelProps) {
  const { t } = strings;
  const rows = useMemo<TimelineRow[]>(() => {
    const thread = threadMessages(messages, root);
    const list = thread.root ? [thread.root, ...thread.replies] : thread.replies;
    return list.map((message, index) => ({
      kind: "message",
      key: message.id,
      message,
      head: index === 0 || list[index - 1]!.author !== message.author,
    }));
  }, [messages, root]);
  return (
    <aside className="hc-thread" aria-label={t("thread.title")}>
      <header className="hc-thread-header">
        <span className="hc-thread-title">{t("thread.title")}</span>
        <button
          type="button"
          className="hc-icon-button"
          aria-label={t("thread.close")}
          title={t("thread.close")}
          onClick={onClose}
        >
          ×
        </button>
      </header>
      <Timeline
        conversation={`thread:${root}`}
        rows={rows}
        people={people}
        me={me}
        strings={strings}
        loadingOlder={false}
        onLoadOlder={() => undefined}
        onReact={onReact}
        onEdit={onEdit}
        onRetract={onRetract}
        className="in-thread"
      />
      <Composer placeholder={t("composer.thread")} label={t("composer.thread")} disabled={!canSend} onSend={onSend} />
    </aside>
  );
}
