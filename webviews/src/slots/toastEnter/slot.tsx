/** @jsxImportSource ../../kit/closed */
// A closed file (tsconfig.closed.json): no raw element, `style` or `className` compiles here.
// A toast's arrival as a theme slot (schemas/theme/slots.json `toast.enter`): what a toast draws as it
// enters the stack. NoticeStack.tsx owns the queue, the timer and the card (Notice.tsx); NoticeDeck.tsx
// owns the deck's places and its fly-in (`.ui-notice-deck-card[data-phase]`). The slot draws around the
// card, inside its place.
import type { ReactNode } from "react";
import { defineSlot } from "../registry";

export type ToastEnterProps = {
  /** The toast's card (Notice.tsx `.ui-notice`). */
  children: ReactNode;
  /** The notice's kind ("toast", "error", ...). */
  kind: string;
};

export const toastEnterSlot = defineSlot<ToastEnterProps>("toast.enter");
