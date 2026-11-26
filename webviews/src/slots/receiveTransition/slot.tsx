// A reply's arrival in the transcript as a theme slot (schemas/theme/slots.json `chat.receiveTransition`):
// the box an agent's reply draws its words in, under the live line while it streams. MessageRow.tsx
// owns the reply's Markdown (RevealedMarkdown, its reveal and streaming) and its action row; the slot
// draws only what holds the reply.
import type { ReactNode } from "react";
import { defineSlot } from "../registry";

export type ReceiveTransitionProps = {
  /** The reply's words (RevealedMarkdown `.cv-reply`). */
  children: ReactNode;
  /** The reply is still streaming in: its first words have arrived and more are coming. */
  streaming: boolean;
};

export const receiveTransitionSlot = defineSlot<ReceiveTransitionProps>("chat.receiveTransition");
