// A transcript row's hover as a theme slot (schemas/theme/slots.json `row.hover`): the action row a
// finished reply reveals on hover or keyboard focus (Copy, Pin, Read aloud, Reply, More, its time).
// MessageActions.tsx ReplyActions owns the buttons; the slot draws the row that holds them, whose
// reveal is conversation.css's (`.acpmux-assistant:hover .cv-reply-actions`).
import type { ReactNode } from "react";
import { defineSlot } from "../registry";

export type RowHoverProps = {
  /** The row's buttons and time. */
  children: ReactNode;
};

export const rowHoverSlot = defineSlot<RowHoverProps>("row.hover");
