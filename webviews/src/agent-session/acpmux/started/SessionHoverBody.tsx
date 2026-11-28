import { type FocusEvent } from "react";
import { type SessionHoverStore, useSessionHoverInfo } from "./sessionHover";
import { SessionHoverContent } from "./SessionHoverCard";

export function SessionHoverBody({
  store,
  sessionId,
  buttonRef,
  onOpen,
  onEscape,
  onBlur,
  onFocus,
}: {
  store: SessionHoverStore;
  sessionId: string;
  buttonRef: { current: HTMLButtonElement | null };
  onOpen(): void;
  onEscape(): void;
  onBlur(event: FocusEvent<HTMLElement>): void;
  onFocus(): void;
}) {
  const info = useSessionHoverInfo(store, sessionId);
  if (!info) return null;
  return (
    <SessionHoverContent
      info={info}
      buttonRef={buttonRef}
      onOpen={onOpen}
      onEscape={onEscape}
      onBlur={onBlur}
      onFocus={onFocus}
    />
  );
}
