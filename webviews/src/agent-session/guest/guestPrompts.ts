// The guest's own messages (design/chat-multiplayer.md sections 3 and 4.3): each one has a
// `client_id` made once, when it is written, and kept with its text in this tab's sessionStorage, so
// a resend after a dropped socket or a reload is the same prompt (the daemon turns the id into one
// acpmux prompt id, and acpmux runs one id once). The room answers with `prompt_state`: held until
// the owner decides, then approved or declined; refused (with a reason) when the daemon would not
// hold it. A message the room never acknowledged stays `sending` and goes again on the next snapshot.
import type { GuestPromptState } from "./shareSocket";

export type GuestPromptStatus = "sending" | GuestPromptState["state"];
export type GuestPrompt = { clientId: string; text: string; at: number; state: GuestPromptStatus; reason?: string };

/** The room takes a prompt's text up to 32 KiB (`guest_prompt`). */
export const PROMPT_MAX_BYTES = 32 * 1024;
/** Decided messages kept; every waiting one is kept whatever the count. */
const DECIDED_KEPT = 16;

export const promptBytes = (text: string) => new TextEncoder().encode(text).length;
/** Whether the message is still waiting on the room or the owner. */
export const isOpen = (prompt: GuestPrompt) => prompt.state === "sending" || prompt.state === "held";

const key = (shareId: string) => `cmux.guest.${shareId}.prompts`;
const STATES = new Set(["sending", "held", "approved", "declined", "removed", "refused"]);

function read(storage: Storage, shareId: string): GuestPrompt[] {
  try {
    const kept = JSON.parse(storage.getItem(key(shareId)) ?? "[]");
    return Array.isArray(kept)
      ? kept.filter(
          (prompt): prompt is GuestPrompt =>
            typeof prompt?.clientId === "string" && typeof prompt.text === "string" && STATES.has(prompt.state),
        )
      : [];
  } catch {
    return [];
  }
}

const newClientId = (random: (bytes: Uint8Array) => Uint8Array) =>
  Array.from(random(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("");

export class GuestPrompts {
  private prompts: GuestPrompt[];
  private readonly listeners = new Set<() => void>();

  constructor(
    private readonly shareId: string,
    private readonly storage: Storage,
    private readonly random: (bytes: Uint8Array) => Uint8Array = (bytes) => crypto.getRandomValues(bytes),
    private readonly now: () => number = Date.now,
  ) {
    this.prompts = read(storage, shareId);
  }

  /** The messages, oldest first; a new array after each change (useSyncExternalStore). */
  list = (): readonly GuestPrompt[] => this.prompts;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  /** A new message, `sending` until the room answers. */
  add(text: string): GuestPrompt {
    const prompt: GuestPrompt = { clientId: newClientId(this.random), text, at: this.now(), state: "sending" };
    this.set([...this.prompts, prompt]);
    return prompt;
  }

  /** A `prompt_state` from the room; one for a message this tab does not hold is ignored. */
  update(state: GuestPromptState): void {
    if (!STATES.has(state.state) || !this.prompts.some((prompt) => prompt.clientId === state.client_id)) return;
    this.set(
      this.prompts.map((prompt) =>
        prompt.clientId === state.client_id
          ? { ...prompt, state: state.state, ...(state.reason ? { reason: state.reason } : {}) }
          : prompt,
      ),
    );
  }

  /** A snapshot's prompt states (this guest's held ones and its newest decided ones). */
  snapshot(states: readonly GuestPromptState[]): void {
    for (const state of states) this.update(state);
  }

  /** Messages the room took but the owner has not decided: the snapshot asks `prompt_status` for them. */
  held(): string[] {
    return this.prompts.filter((prompt) => prompt.state === "held").map((prompt) => prompt.clientId);
  }

  /** Messages the room never acknowledged: sent again, with the same client id, on each snapshot. */
  unsent(): GuestPrompt[] {
    return this.prompts.filter((prompt) => prompt.state === "sending");
  }

  private set(next: GuestPrompt[]): void {
    const decided = next.filter((prompt) => !isOpen(prompt)).slice(-DECIDED_KEPT);
    this.prompts = next.filter((prompt) => isOpen(prompt) || decided.includes(prompt));
    try {
      this.storage.setItem(key(this.shareId), JSON.stringify(this.prompts));
    } catch {
      // A full or refused storage only loses the messages across a reload.
    }
    for (const listener of this.listeners) listener();
  }
}
