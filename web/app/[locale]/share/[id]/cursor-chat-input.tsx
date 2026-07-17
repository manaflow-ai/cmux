"use client";

import { useCallback, useState } from "react";
import { useTranslations } from "next-intl";

/**
 * Small floating input rendered at the local user's cursor position (in
 * workspace coordinates). Enter sends, Escape closes.
 */
export function CursorChatInput({
  x,
  y,
  workspaceWidth,
  workspaceHeight,
  onSend,
  onClose,
}: {
  x: number;
  y: number;
  workspaceWidth: number;
  workspaceHeight: number;
  onSend: (text: string) => void;
  onClose: () => void;
}) {
  const t = useTranslations("share");
  const [text, setText] = useState("");

  const focusRef = useCallback((node: HTMLInputElement | null) => {
    node?.focus();
  }, []);

  return (
    <div
      className="absolute z-20"
      style={{
        left: x * workspaceWidth,
        top: y * workspaceHeight + 22,
      }}
    >
      <input
        ref={focusRef}
        value={text}
        onChange={(event) => setText(event.target.value)}
        onBlur={onClose}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            const trimmed = text.trim();
            if (trimmed) onSend(trimmed);
            onClose();
          } else if (event.key === "Escape") {
            onClose();
          }
          event.stopPropagation();
        }}
        placeholder={t("cursorChat.placeholder")}
        className="w-[220px] rounded-full border border-neutral-700 bg-neutral-950/95 px-3 py-1.5 text-[12px] text-neutral-100 shadow-lg outline-none placeholder:text-neutral-500 focus:border-neutral-500"
      />
    </div>
  );
}
