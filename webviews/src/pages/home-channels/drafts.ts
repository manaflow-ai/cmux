// The page's live drafts: at most one running agent turn per conversation, as its
// `conversation-draft` items say (the same rules as CmuxHomeCore's HomeDraftBook, which the
// native Home uses). A turn ends with its `done` item, its posted reply (same author and key) or
// its author's typing off. A draft item of a turn that ended and arrives late is dropped, so a
// posted reply never gets its draft back. View state only: nothing here is stored.
import type { HomeDraftItem, HomeMessage } from "./types";

export interface HomeDraft {
  participant: string;
  turn: string;
  /** The reply so far: the talk segments in order, joined by a blank line. */
  text: string;
}

interface Turn {
  participant: string;
  turn: string;
  segments: Map<number, string>;
  lastSeq: number;
  /** A seq was missed: nothing new shows until the next `fresh` item. */
  gap: boolean;
}

const ENDED_LIMIT = 256;

export class DraftBook {
  private readonly live = new Map<string, Turn>();
  private readonly ended: string[] = [];

  /** The visible draft of a conversation, if its turn has talk text. */
  draft(conversation: string): HomeDraft | undefined {
    const turn = this.live.get(conversation);
    if (!turn) return undefined;
    const text = [...turn.segments.keys()]
      .sort((a, b) => a - b)
      .map((key) => turn.segments.get(key) ?? "")
      .join("\n\n");
    return text ? { participant: turn.participant, turn: turn.turn, text } : undefined;
  }

  apply(item: HomeDraftItem): void {
    if (this.ended.includes(item.turn)) return;
    if (item.done) {
      this.end(item.conversation, (turn) => turn.turn === item.turn);
      return;
    }
    const current = this.live.get(item.conversation);
    // A new turn replaces the live one: the old turn ended, so its late items stay dropped.
    if (current && current.turn !== item.turn) this.remember(current.turn);
    const turn: Turn =
      current && current.turn === item.turn
        ? current
        : { participant: item.participant, turn: item.turn, segments: new Map(), lastSeq: 0, gap: false };
    const follows = turn.lastSeq !== 0 && item.seq === turn.lastSeq + 1;
    turn.lastSeq = Math.max(turn.lastSeq, item.seq);
    if (item.talk) {
      if (item.fresh) {
        turn.gap = false;
        turn.segments.set(item.segment, item.text);
      } else if (turn.gap || !follows) {
        turn.gap = true;
      } else {
        turn.segments.set(item.segment, (turn.segments.get(item.segment) ?? "") + item.text);
      }
    }
    this.live.set(item.conversation, turn);
  }

  /** A message was committed: its draft (same author and key) ends. */
  posted(message: HomeMessage): void {
    if (!message.clientMessageId) return;
    this.remember(message.clientMessageId);
    this.end(
      message.conversation,
      (turn) => turn.turn === message.clientMessageId && turn.participant === message.author,
    );
  }

  /** The participant stopped typing: its turn ended. */
  typingOff(conversation: string, participant: string): void {
    this.end(conversation, (turn) => turn.participant === participant);
  }

  /** A reconnect or an inbox refetch: running replies are re-sent by the owner if still live. */
  clear(): void {
    this.live.clear();
  }

  private end(conversation: string, matches: (turn: Turn) => boolean): void {
    const turn = this.live.get(conversation);
    if (!turn || !matches(turn)) return;
    this.live.delete(conversation);
    this.remember(turn.turn);
  }

  private remember(turn: string): void {
    if (this.ended.includes(turn)) return;
    this.ended.push(turn);
    if (this.ended.length > ENDED_LIMIT) this.ended.splice(0, this.ended.length - ENDED_LIMIT);
  }
}
