// Data model of a conversation. A thread is a list of protocol turns (protocol.ts: the
// Codex app-server's Turn / ThreadItem types, loaded from rollouts by rollout.ts); what the
// transcript shows for each turn is derived (activity.ts, turnEnd.ts), and which
// disclosures are open is UI state keyed by the derived stable ids. Screens add the parts
// a capture shows that the protocol does not carry (timestamps, banners, scroll position).
// <Transcript> renders it into a real scroll container.
import type { TurnMessageProps } from "./TurnMessage";
import type { EditedFile } from "./cards";
import type { TurnActionsKind, ThinkingProps } from "./messages";
import type { ScrollPosition } from "./useScrollPosition";
import type { Clock } from "./timestamps";

export type Message = TurnMessageData | UserMessageData | AssistantMessageData | SystemMessageData;

/**
 * One protocol turn: its user message, activity, final answer and closing cards, all
 * derived from `turn.items`. `open` lists the disclosures open at first render (the turn
 * id for "Worked for", `agent-activity-group:<first item id>` for a group, an item id for
 * a command / tool call / diff).
 */
export type TurnMessageData = { role: "turn" } & TurnMessageProps;

export type UserMessageData = {
  role: "user";
  /** Plain text (Codex shows user messages verbatim, whitespace preserved). */
  text: string;
  /** Copy / edit buttons visible under the bubble (after a stop, or on hover). */
  actions?: boolean;
};

export type AssistantMessageData = {
  role: "assistant";
  parts: AssistantPart[];
  /** Buttons closing the turn; omitted while the turn is still streaming. */
  actions?: TurnActionsKind;
};

/** A centered line between messages the protocol does not carry (turn timestamps are
 * derived from the turns, see `Conversation.clock`). */
export type SystemMessageData = { role: "system"; text: string };

export type AssistantPart =
  | { type: "markdown"; source: string }
  /** Streaming placeholder before any text arrives. */
  | ({ type: "thinking" } & ThinkingProps)
  | {
      type: "edited-files";
      files: EditedFile[];
      visible?: number;
      count?: number;
      additions?: number;
      deletions?: number;
    };

/** What replaces the composer, e.g. when the thread is open in another app. */
export type ThreadBanner = {
  kind: "open-elsewhere";
  title?: string;
  body?: string;
  actions?: string[];
};

export type Conversation = {
  messages: Message[];
  /** Captured scroll position of the transcript. */
  scroll?: ScrollPosition;
  /** `streaming` while a turn runs, `stopped` after the user stopped it. */
  status?: "idle" | "streaming" | "stopped";
  banner?: ThreadBanner;
  /**
   * When the screen shows the thread (a capture's time). With it, timestamp lines between
   * turns are derived from the turns' times (timestamps.ts); without it none are drawn.
   */
  clock?: Clock;
};
