// The /side interaction as a theme slot (schemas/theme/slots.json `chat.side`): the note a side question
// opens beside the thread, which holds the question and its answer. BtwAside.tsx owns what is inside
// (the head, Dismiss, the question, the answer or its error); the slot draws the note's box around it.
import type { ReactNode } from "react";
import { defineSlot } from "../registry";

export type SideProps = {
  /** The note's head, its question and its answer (BtwAside.tsx). */
  children: ReactNode;
  /** The note's accessible name ("Side question"), already translated. */
  label: string;
  /** The answer has not come back yet. */
  pending: boolean;
};

export const sideSlot = defineSlot<SideProps>("chat.side");
