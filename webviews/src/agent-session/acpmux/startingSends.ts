// Prompts sent while a new chat starts. A slow start (a remote machine, an agent slow to come up)
// once held the first prompt in the composer under a spinner, and the next Send only said it was
// still sending (Leo, 2026-10-21: "what would be better is if potentially, like, we just have them
// send out as, like, queued up stuff, right? ... and then you can just keep on sending messages").
// Each prompt now leaves the composer at once and shows as a queued row; they go out one by one, in
// the order they were sent, each once acpmux took the one before. A refused one comes back to the
// composer with every prompt behind it, so nothing is lost and nothing goes out of order.
import type { ComposerAttachment } from "./attachments";
import { attachedImages, sentPrompt } from "./direct";
import type { SendGesture } from "./heldPrompt";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";

/// `at`: when it was sent (Date.now()). `sentIn`: the chat shown when it was sent (`StartingPlace`).
export type StartingSend = {
  id: string;
  text: string;
  attachments: ComposerAttachment[];
  at: number;
  sentIn: StartingPlace;
};
/// Where the pane is: the chat it shows (none: a new chat not started yet) and its visit, the
/// client's `selectionToken`, which moves on every selection.
export type StartingPlace = { chat?: string; visit: number };
/// `lost`: an edit saved while the prompt was going, which comes back only once it went.
/// `gesture`: the Enter or click the composer bound to it while it held it for its files.
type Item = StartingSend & { going: boolean; lost?: string; gesture?: SendGesture };
/// Sends a queued prompt, with the gesture its send bound, if any.
type Go = (text: string, attachments: ComposerAttachment[], gesture?: SendGesture) => Promise<unknown>;

export class StartingSends {
  private items: Item[] = [];
  /// Rows a refusal gave back to the composer.
  private returned = new Set<string>();
  private tail: Promise<void> = Promise.resolve();

  /**
   * `changed` gets the rows to show, oldest first, whenever they change. `giveBack` puts a prompt
   * back in the composer, before what it holds (Composer `restore`); `error` is the refusal of the
   * prompt that was refused, none for those behind it.
   */
  constructor(
    private readonly changed: (rows: readonly StartingSend[]) => void,
    private readonly giveBack: (text: string, attachments: ComposerAttachment[], error?: unknown) => void,
    /// Where the pane is now: each prompt added keeps where it was sent.
    private readonly place: () => StartingPlace,
  ) {}

  /** The prompts waiting or going, oldest first. */
  get rows(): readonly StartingSend[] {
    return this.items.map(({ id, text, attachments, at, sentIn }) => ({ id, text, attachments, at, sentIn }));
  }
  /** Some prompt has not been taken yet: a prompt sent now waits behind it. */
  get busy(): boolean {
    return this.items.length > 0;
  }
  /** Whether `id` names one of these rows rather than a prompt in acpmux's queue. */
  owns(id: string): boolean {
    return this.items.some((item) => item.id === id);
  }

  /**
   * An edit of row `id` that could not be saved (ComposerQueue `onLost`). Its text goes back to the
   * composer once the prompt went; never when a refusal gave the prompt back, which is there already.
   */
  lost(id: string, text: string) {
    if (this.returned.has(id)) return;
    const item = this.items.find((each) => each.id === id);
    if (item) item.lost = text;
    else this.giveBack(text, []);
  }

  /**
   * Adds a prompt; `go` sends it and settles once acpmux took it, or rejects when it was refused.
   * `gesture`: the Enter or click the composer bound to a send it held for its files (a pasted
   * image's upload may have spent the host's grant since); `go` gets it with the prompt.
   */
  /// `id`: the prompt id its send goes with, so the chat's own row for it keeps the row drawn here
  /// (`withStartingPrompt`).
  add(text: string, attachments: ComposerAttachment[], go: Go, gesture?: SendGesture, id?: string) {
    const item: Item = {
      id: id ?? `starting-${crypto.randomUUID()}`,
      text,
      attachments,
      at: Date.now(),
      sentIn: this.place(),
      going: false,
      ...(gesture ? { gesture } : {}),
    };
    this.items.push(item);
    this.emit();
    this.tail = this.tail.then(() => this.run(item, go));
  }

  /** Withdraws a prompt that has not gone yet; false once it went. */
  remove(id: string): boolean {
    const index = this.items.findIndex((item) => item.id === id && !item.going);
    if (index < 0) return false;
    this.items.splice(index, 1);
    this.emit();
    return true;
  }

  /** Changes the text of a prompt that has not gone yet; false once it went. */
  edit(id: string, text: string): boolean {
    const item = this.items.find((each) => each.id === id && !each.going);
    if (!item) return false;
    item.text = text;
    this.emit();
    return true;
  }

  private async run(item: Item, go: Go) {
    // Removed, or given back with a refused prompt before it.
    if (!this.items.includes(item)) return;
    item.going = true;
    try {
      await go(item.text, item.attachments, item.gesture);
    } catch (error) {
      // This prompt and every one behind it come back; the composer puts each before what it
      // holds, so the last goes back first and they read in the order they were sent.
      const back = this.items.splice(this.items.indexOf(item));
      for (const each of back) this.returned.add(each.id);
      this.emit();
      for (const each of back.reverse()) this.giveBack(each.text, each.attachments, each === item ? error : undefined);
      return;
    }
    this.items.splice(this.items.indexOf(item), 1);
    this.emit();
    if (item.lost) this.giveBack(item.lost, []);
  }

  private emit() {
    this.changed(this.rows);
  }
}

/// The row a starting prompt draws as: the one the chat's client draws for it once it went
/// (direct.ts `sendNow`, `local-<promptId>`), so it stays the same row, and pending, so the
/// Thinking line draws under it in its start look (conversation/turns.ts `waiting`).
/// Its text, pastes and inline parts are the ones that row draws (direct.ts `sentPrompt`).
function startingRow(send: StartingSend): AcpmuxRow {
  const { inline, text, pasted } = sentPrompt(send.text, send.attachments);
  return {
    id: `local-${send.id}`,
    version: 0,
    at: send.at,
    kind: "user",
    text,
    ...(pasted.length ? { pasted } : {}),
    ...(inline ? { inlineParts: inline.parts } : {}),
    ...(send.attachments.length
      ? { images: attachedImages(send.attachments), retryAttachments: send.attachments }
      : {}),
    pending: true,
    queued: send.id,
  };
}

/**
 * A new chat's first prompt is its first row from the send, while the chat still starts: it
 * leaves the composer for the transcript in one move, with its Thinking line, instead of waiting
 * as a queued row that jumps into the transcript once the agent is up (Leo, 2026-11-09: "there's
 * the gap between when you send off a message versus otherwise, like it's like there's a one-two
 * discontinuity"). Prompts sent after it wait in the queue, as they do behind any running turn.
 * Once the chat's client draws that prompt's row (the same id) it is the client's.
 */
export function withStartingPrompt(raw: AcpmuxSnapshot, starting: readonly StartingSend[]): AcpmuxSnapshot {
  const first = starting[0];
  if (!first || raw.rows.some((row) => row.kind === "user")) return raw;
  return { ...raw, rows: [...raw.rows, startingRow(first)] };
}

/**
 * The starting prompts the chat shown draws: those sent in it, and, in the chat a new chat took,
 * those sent in that new chat before it took its session (`started`: the client's `startedChat`).
 * Never another chat's: one opened while a new chat still starts has its own transcript and queue,
 * and an empty one would otherwise draw the new chat's first prompt as its own.
 */
export function startingIn(
  starting: readonly StartingSend[],
  here: StartingPlace,
  started: { sessionId: string; visit: number } | undefined,
): readonly StartingSend[] {
  const shown = starting.filter(({ sentIn }) =>
    sentIn.chat
      ? sentIn.chat === here.chat
      : here.chat
        ? started?.sessionId === here.chat && started.visit === sentIn.visit
        : sentIn.visit === here.visit,
  );
  return shown.length === starting.length ? starting : shown;
}

/// The starting prompts the composer's queue still draws: not one the transcript draws.
export function queuedStartingSends(
  starting: readonly StartingSend[],
  rows: readonly AcpmuxRow[],
): readonly StartingSend[] {
  if (!starting.length) return starting;
  const drawn = new Set(rows.map((row) => row.id));
  return starting.filter((send) => !drawn.has(`local-${send.id}`));
}
