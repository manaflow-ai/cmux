"use client";

// Multiplayer composer strip for agent-chat panes (slice 2). The host is the
// single serializer: local edits go up as splice ops against the last
// acknowledged revision, `compose-state` comes back as authoritative text.
// Remote carets render through a mirror <div> that reproduces the textarea's
// text layout, the standard trick for caret geometry in a textarea.

import { useRef, useState, type CSSProperties, type ReactNode } from "react";
import { useTranslations } from "next-intl";

import { spliceDiff } from "./compose-ops";
import { participantColor } from "./share-colors";
import type { ShareClient } from "./share-connection";
import type { Participant } from "./share-protocol";
import { useStoreValue } from "./use-store";

export function SharedComposer({
  client,
  field,
  participants,
  selfUser,
}: {
  client: ShareClient;
  field: string;
  participants: Participant[];
  selfUser: string | null;
}): ReactNode {
  const t = useTranslations("share");
  const composeStates = useStoreValue(client.compose);
  const authoritative = composeStates.get(field) ?? { rev: 0, text: "", carets: [] };
  const [draft, setDraft] = useState<{ baseRev: number; text: string } | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const byUser = new Map(participants.map((p) => [p.user, p]));

  // Adopt authoritative text once it has caught up with our last edit.
  const text =
    draft && draft.baseRev >= authoritative.rev ? draft.text : authoritative.text;
  if (draft && draft.baseRev < authoritative.rev && draft.text !== authoritative.text) {
    // Host serialized someone else's op after ours; authoritative wins.
    setDraft(null);
  }

  const onChange = (next: string): void => {
    const op = spliceDiff(text, next);
    if (!op) return;
    const caretPos = textareaRef.current?.selectionStart ?? next.length;
    // Optimistic: assume the host applies our op on top of `rev` and bumps it.
    setDraft({ baseRev: authoritative.rev + 1, text: next });
    client.sendCompose(field, authoritative.rev, [op], { start: caretPos, end: caretPos });
  };

  const remoteCarets = authoritative.carets.filter((c) => c.user !== selfUser);

  return (
    <div className="relative border-t border-neutral-800 bg-[#0f0f0f] p-2">
      <p className="mb-1 text-[10px] uppercase tracking-wider text-neutral-500">
        {t("composerLabel")}
      </p>
      <div className="relative">
        {/* Mirror layer for remote caret geometry. */}
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0 whitespace-pre-wrap break-words px-2 py-1.5 font-mono text-xs text-transparent"
        >
          {remoteCarets.map((caret) => {
            const participant = byUser.get(caret.user);
            const color = participantColor(participant?.color ?? 0);
            const before = [...authoritative.text].slice(0, caret.start).join("");
            return (
              <span key={caret.user}>
                <span className="invisible">{before}</span>
                <span
                  className="relative"
                  style={{ borderLeft: `2px solid ${color}` } satisfies CSSProperties}
                >
                  <span
                    className="absolute -top-3.5 left-0 rounded px-1 text-[9px] leading-tight text-white"
                    style={{ backgroundColor: color }}
                  >
                    {participant?.email?.split("@")[0] ?? caret.user}
                  </span>
                </span>
              </span>
            );
          })}
        </div>
        <textarea
          ref={textareaRef}
          value={text}
          rows={2}
          onChange={(e) => onChange(e.target.value)}
          placeholder={t("composerPlaceholder")}
          className="relative w-full resize-none rounded border border-neutral-800 bg-transparent px-2 py-1.5 font-mono text-xs text-neutral-200 outline-none placeholder:text-neutral-600 focus:border-[#2d8cff]/60"
        />
      </div>
    </div>
  );
}
