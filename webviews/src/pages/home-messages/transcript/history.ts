// Up and Down in the message box recall the messages the person sent, like a shell's history (a port
// of MessagesLab's ComposerHistory.swift; Lawrence 2026-10-19: "Up arrow ... like it is history").
// - The first Up saves the draft and shows the newest entry; each further Up an older one (it stops
//   at the oldest).
// - Down shows a newer entry; Down from the newest gives the draft back.
// - An edit to a shown entry ends the browse: the edited text is the draft. A send ends it too.
// - The entries are the person's own messages in the loaded transcript, newest first, so the history
//   is the conversation's own with no second store; a browse snapshots them when it begins.
import type { HomeMessage } from "../../home-channels/types";

export class ComposerHistory {
  private snapshot: string[] = [];
  private index: number | undefined;
  private savedDraft = "";

  get isBrowsing(): boolean {
    return this.index !== undefined;
  }

  /** The entry the box shows now; undefined when it shows the draft. */
  get shown(): string | undefined {
    return this.index === undefined ? undefined : this.snapshot[this.index];
  }

  /** One step: the text the box should show, or undefined when the step changes nothing. */
  step(direction: "older" | "newer", current: string, entries: () => string[]): string | undefined {
    if (direction === "older") {
      if (this.index === undefined) {
        const all = entries();
        if (all.length === 0) return undefined;
        this.snapshot = all;
        this.savedDraft = current;
        this.index = 0;
        return all[0];
      }
      if (this.index + 1 >= this.snapshot.length) return undefined;
      this.index += 1;
      return this.snapshot[this.index];
    }
    if (this.index === undefined) return undefined;
    if (this.index === 0) {
      const draft = this.savedDraft;
      this.end();
      return draft;
    }
    this.index -= 1;
    return this.snapshot[this.index];
  }

  /** The box's text changed: a change away from the shown entry (an edit) ends the browse. */
  textChanged(text: string): void {
    const shown = this.shown;
    if (shown !== undefined && shown !== text) this.end();
  }

  end(): void {
    this.snapshot = [];
    this.index = undefined;
    this.savedDraft = "";
  }
}

/** My sent messages' text, newest first: retracted and text-less ones skipped, and a repeat of the
 * entry just newer than it dropped (a shell's `ignoredups`). */
export function historyEntries(messages: readonly HomeMessage[], me: string): string[] {
  const out: string[] = [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]!;
    if (message.author !== me || message.retracted) continue;
    const text = message.parts
      .filter((part) => part.type === "text")
      .map((part) => (part.type === "text" ? part.text : ""))
      .join("\n");
    if (!text.trim() || out.at(-1) === text) continue;
    out.push(text);
  }
  return out;
}

/** Whether an arrow in the field steps the history: Up only with the caret on the first line, Down
 * only on the last (a multi-line draft keeps its caret arrows). */
export function historyTakesArrow(direction: "older" | "newer", text: string, caret: number): boolean {
  return direction === "older" ? !text.slice(0, caret).includes("\n") : !text.slice(caret).includes("\n");
}
