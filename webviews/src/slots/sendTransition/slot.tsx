// A sent prompt's arrival in the transcript as a theme slot (schemas/theme/slots.json
// `chat.sendTransition`): the prompt's bubble, which the send motion (conversation.css SEND-ENTRANCE,
// `.acpmux-row--message-enter`) brings in. UserBubble.tsx owns the row, its text, attachments and
// footer; the slot draws only the bubble box around the prompt's words.
import type { ReactNode } from "react";
import { defineSlot } from "../registry";

export type SendTransitionProps = {
  /** The prompt's words, drawn inside the bubble (PromptText or InlinePromptContent). */
  children: ReactNode;
};

export const sendTransitionSlot = defineSlot<SendTransitionProps>("chat.sendTransition");
