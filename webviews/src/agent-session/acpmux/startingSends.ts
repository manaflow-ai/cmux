// Prompts sent while a new chat starts. A slow start (a remote machine, an agent slow to come up)
// once held the first prompt in the composer under a spinner, and the next Send only said it was
// still sending (Leo, 2026-10-21: "what would be better is if potentially, like, we just have them
// send out as, like, queued up stuff, right? ... and then you can just keep on sending messages").
// Each prompt now leaves the composer at once and shows as a queued row; they go out one by one, in
// the order they were sent, each once acpmux took the one before. A refused one comes back to the
// composer with every prompt behind it, so nothing is lost and nothing goes out of order.
import type { ComposerAttachment } from "./attachments";
import { attachedImages } from "./direct";
import type { SendGesture } from "./heldPrompt";
import { carryInline, inlinePlainText } from "./inlinePrompt";
import type { QueuedPrompt } from "./model";

export type StartingSend = { id: string; text: string; attachments: ComposerAttachment[] };

/// A prompt waiting for the new chat as its queued row draws it, as a prompt acpmux queued draws:
/// its words, and its images under them from the pane's own bytes. Never the draft's text as it is,
/// whose attachments are tokens of their ids: an image pasted into a new chat's first prompt read as
/// its UUID until the chat took it (#41016).
export function startingQueueEntry(row: StartingSend): QueuedPrompt {
  const images = attachedImages(row.attachments);
  return {
    id: row.id,
    prompt: inlinePlainText(row.text, row.attachments),
    sending: true,
    ...(images.length ? { images } : {}),
  };
}
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
  ) {}

  /** The prompts waiting or going, oldest first. */
  get rows(): readonly StartingSend[] {
    return this.items.map(({ id, text, attachments }) => ({ id, text, attachments }));
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
  add(text: string, attachments: ComposerAttachment[], go: Go, gesture?: SendGesture) {
    const item: Item = {
      id: `starting-${crypto.randomUUID()}`,
      text,
      attachments,
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

  /**
   * Changes the text of a prompt that has not gone yet (its row's words, `startingQueueEntry`): its
   * attachments keep their places in it. False once it went.
   */
  edit(id: string, text: string): boolean {
    const item = this.items.find((each) => each.id === id && !each.going);
    if (!item) return false;
    item.text = carryInline(item.text, text, item.attachments);
    // A pasted or text chip's text is in the edited words now (the row shows it inline): its chip
    // goes, or the prompt would carry that text twice, the chip's copy after the words.
    item.attachments = item.attachments.filter(
      (attachment) => attachment.kind !== "pasted" && attachment.kind !== "text",
    );
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
