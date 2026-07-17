"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import type { Participant } from "./protocol";
import { displayName, participantColor } from "./palette";
import { useNow } from "./use-now";

export interface ChatEntry {
  id: number;
  participantId: string;
  text: string;
  ts: number;
}

function relativeTime(
  ts: number,
  now: number,
  t: ReturnType<typeof useTranslations<"share">>,
): string {
  const seconds = Math.max(0, Math.round((now - ts) / 1000));
  if (seconds < 60) return t("chat.justNow");
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return t("chat.minutesAgo", { minutes });
  const hours = Math.round(minutes / 60);
  return t("chat.hoursAgo", { hours });
}

export function ChatPanel({
  entries,
  participants,
  onSend,
}: {
  entries: ChatEntry[];
  participants: Map<string, Participant>;
  onSend: (text: string) => void;
}) {
  const t = useTranslations("share");
  const [collapsed, setCollapsed] = useState(false);
  const [draft, setDraft] = useState("");
  const now = useNow();

  const submit = () => {
    const text = draft.trim();
    if (!text) return;
    onSend(text);
    setDraft("");
  };

  return (
    <div className="pointer-events-auto fixed bottom-4 right-4 z-30 w-[300px] overflow-hidden rounded-lg border border-neutral-800 bg-neutral-950/95 shadow-xl backdrop-blur">
      <button
        type="button"
        className="flex w-full items-center justify-between px-3 py-2 text-left text-[12px] font-medium text-neutral-300 hover:bg-neutral-900"
        onClick={() => setCollapsed((c) => !c)}
      >
        <span>{t("chat.title")}</span>
        <span className="text-neutral-500">{collapsed ? "+" : "−"}</span>
      </button>
      {collapsed ? null : (
        <>
          <div className="flex max-h-[260px] flex-col-reverse gap-1 overflow-y-auto px-3 pb-2">
            {entries.length === 0 ? (
              <p className="py-2 text-[12px] text-neutral-600">
                {t("chat.empty")}
              </p>
            ) : (
              [...entries].reverse().map((entry) => {
                const participant = participants.get(entry.participantId);
                const color = participantColor(participant?.color ?? 0);
                return (
                  <div key={entry.id} className="text-[12px] leading-5">
                    <span
                      className="font-medium"
                      style={{ color: color.base }}
                    >
                      {participant ? displayName(participant) : "…"}
                    </span>{" "}
                    <span className="text-neutral-200">{entry.text}</span>{" "}
                    <span className="text-[10px] text-neutral-600">
                      {relativeTime(entry.ts, now, t)}
                    </span>
                  </div>
                );
              })
            )}
          </div>
          <form
            className="border-t border-neutral-800 p-2"
            onSubmit={(event) => {
              event.preventDefault();
              submit();
            }}
          >
            <input
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              placeholder={t("chat.inputPlaceholder")}
              className="w-full rounded-md border border-neutral-800 bg-neutral-900 px-2 py-1.5 text-[12px] text-neutral-200 outline-none placeholder:text-neutral-600 focus:border-neutral-600"
            />
          </form>
        </>
      )}
    </div>
  );
}
