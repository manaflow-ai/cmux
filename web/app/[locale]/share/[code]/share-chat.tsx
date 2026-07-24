"use client";

// Floating session chat, bottom-right of the workspace. Bubbles typed at the
// cursor land in this same stream (one message list, two entry points).

import { useCallback, useState, type ReactNode } from "react";
import { useTranslations } from "next-intl";

import { participantColor } from "./share-colors";
import {
  MAX_CHAT_TEXT_CHARS,
  type ChatMessage,
  type Participant,
} from "./share-protocol";

export function ChatPanel({
  chat,
  participants,
  selfUser,
  onSend,
}: {
  chat: ChatMessage[];
  participants: Participant[];
  selfUser: string | null;
  onSend: (text: string) => void;
}): ReactNode {
  const t = useTranslations("share");
  const [open, setOpen] = useState(true);
  const [draft, setDraft] = useState("");
  // Message count at the moment the panel was collapsed; unread only exists
  // while collapsed, so no per-render bookkeeping is needed.
  const [seenCount, setSeenCount] = useState(0);
  const newestMessageId = chat.at(-1)?.id ?? null;
  const mountMessageList = useCallback(
    (element: HTMLDivElement | null): void => {
      if (element) {
        element.scrollTop = newestMessageId === null ? 0 : element.scrollHeight;
      }
    },
    [newestMessageId],
  );
  const byUser = new Map(participants.map((p) => [p.user, p]));

  if (!open) {
    const unread = Math.max(0, chat.length - seenCount);
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="absolute bottom-4 right-4 z-50 flex items-center gap-2 rounded-full border border-border bg-background/90 px-4 py-2 text-xs shadow-lg backdrop-blur"
      >
        {t("chatTitle")}
        {unread > 0 ? (
          <span className="rounded-full bg-[#2d8cff] px-1.5 text-[10px] font-semibold text-white">
            {unread}
          </span>
        ) : null}
      </button>
    );
  }

  const submit = (): void => {
    if (draft.trim()) {
      onSend(draft);
      setDraft("");
    }
  };

  return (
    <div className="absolute bottom-4 right-4 z-50 flex max-h-80 w-72 flex-col overflow-hidden rounded-lg border border-border bg-background/95 shadow-xl backdrop-blur">
      <div className="flex items-center justify-between border-b border-border px-3 py-2">
        <span className="text-xs font-medium">{t("chatTitle")}</span>
        <button
          type="button"
          onClick={() => {
            setSeenCount(chat.length);
            setOpen(false);
          }}
          aria-label={t("chatCollapse")}
          className="text-xs text-muted hover:text-foreground"
        >
          –
        </button>
      </div>
      <div
        ref={mountMessageList}
        className="flex-1 space-y-2 overflow-y-auto px-3 py-2"
      >
        {chat.length === 0 ? (
          <p className="text-[11px] text-muted">{t("chatEmpty")}</p>
        ) : (
          chat.map((msg) => {
            const participant = byUser.get(msg.user);
            const color = participantColor(participant?.color ?? 0);
            const mine = msg.user === selfUser;
            return (
              <div key={msg.id} className="text-xs leading-snug">
                <span className="mr-1 inline-block h-2 w-2 rounded-full align-middle" style={{ backgroundColor: color }} />
                <span className="font-medium" style={{ color }}>
                  {mine ? t("chatYou") : (participant?.email ?? msg.user)}
                </span>{" "}
                <span className="whitespace-pre-wrap break-words">{msg.text}</span>
              </div>
            );
          })
        )}
      </div>
      <form
        className="border-t border-border p-2"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <input
          value={draft}
          maxLength={MAX_CHAT_TEXT_CHARS}
          onChange={(e) => setDraft(e.target.value)}
          placeholder={t("chatPlaceholder")}
          className="w-full rounded border border-border bg-transparent px-2 py-1.5 text-xs outline-none placeholder:text-muted focus:border-[#2d8cff]/60"
        />
      </form>
    </div>
  );
}
