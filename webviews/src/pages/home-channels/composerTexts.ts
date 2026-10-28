// The text typed in each conversation's composer and not sent yet, kept for the page's whole mount:
// a reconnect makes a new store (main.tsx) and a discard a new document, and neither loses it
// (the page state's unsent inputs). View state only: nothing reaches the daemon.

/** The page name its saved state carries (pageState.ts). */
export const HOME_CHANNELS_PAGE = "home-channels";

/**
 * The most composer text one save keeps, in characters: the page state holds at most 64 KB
 * (pageLifecycle.ts), and an oversized one is not kept at all, so the oldest drafts go first.
 */
export const COMPOSER_TEXTS_MAX_CHARS = 24 * 1024;

/** What the page keeps across a discard: each conversation's unsent composer text. */
export interface HomeChannelsInputs {
  composers: Record<string, string>;
}

export class ComposerTexts {
  /** By conversation, the most recently typed in last. */
  private readonly texts = new Map<string, string>();

  /** The drafts a discarded document saved (`restoredPageInputs`); invalid entries are dropped. */
  static restored(state: unknown): ComposerTexts {
    const drafts = new ComposerTexts();
    const composers = (state as { composers?: unknown } | null | undefined)?.composers;
    if (!composers || typeof composers !== "object") return drafts;
    for (const [conversation, text] of Object.entries(composers as Record<string, unknown>))
      if (typeof text === "string") drafts.set(conversation, text);
    return drafts;
  }

  get(conversation: string): string {
    return this.texts.get(conversation) ?? "";
  }

  /** The composer's text changed; an empty or blank one is no draft. */
  set(conversation: string, text: string): void {
    this.texts.delete(conversation);
    if (text.trim()) this.texts.set(conversation, text);
  }

  /** The newest drafts that fit in `COMPOSER_TEXTS_MAX_CHARS`. */
  pageInputs(): HomeChannelsInputs {
    const composers: Record<string, string> = {};
    let room = COMPOSER_TEXTS_MAX_CHARS;
    for (const [conversation, text] of [...this.texts].reverse()) {
      if (text.length > room) continue;
      composers[conversation] = text;
      room -= text.length;
    }
    return { composers };
  }
}
