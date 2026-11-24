import type { ComposerAttachment } from "./attachments";

type ComposerRestoreHandle = {
  restore(text: string, attachments: ComposerAttachment[]): void;
};

type ComposerQuoteHandle = {
  quoteReply(markdown: string): void;
};

type HeldBackPrompt = { text: string; attachments: ComposerAttachment[] };

/// Restore a prompt after an async queue action, preserving it while the composer is unmounted.
export function restoreComposerDraft(
  composer: { current: ComposerRestoreHandle | null },
  heldBack: { current: HeldBackPrompt[] | undefined },
  text: string,
  attachments: ComposerAttachment[],
): void {
  const handle = composer.current;
  if (handle) {
    handle.restore(text, attachments);
    return;
  }
  heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
}

/// Quote in Reply while the composer is away (a Sandboxed receipt, a handoff review): the quote
/// waits, in the order picked, and goes in after the draft when the composer comes back.
export function quoteIntoComposer(
  composer: { current: ComposerQuoteHandle | null },
  heldQuotes: { current: string[] | undefined },
  markdown: string,
): void {
  const handle = composer.current;
  if (handle) {
    handle.quoteReply(markdown);
    return;
  }
  heldQuotes.current = [...(heldQuotes.current ?? []), markdown];
}

/// A composer mounted: what waited for it goes in, once. Held-back prompts first (a restore puts
/// its prompt ahead of the draft), then held quotes, which append after it.
export function replayHeldForComposer(
  handle: (ComposerRestoreHandle & ComposerQuoteHandle) | null,
  heldBack: { current: HeldBackPrompt[] | undefined },
  heldQuotes: { current: string[] | undefined },
): void {
  if (!handle) return;
  const waiting = heldBack.current;
  heldBack.current = undefined;
  for (const back of waiting ?? []) handle.restore(back.text, back.attachments);
  const quotes = heldQuotes.current;
  heldQuotes.current = undefined;
  for (const quote of quotes ?? []) handle.quoteReply(quote);
}

/// A composer that went while its editor was still being made hands back the quotes it had taken:
/// they go into the composer there is now, or wait (ahead of any picked since) for the next one.
export function handBackQuotes(
  composer: { current: ComposerQuoteHandle | null },
  heldQuotes: { current: string[] | undefined },
  quotes: string[],
): void {
  if (!quotes.length) return;
  const handle = composer.current;
  if (handle) {
    for (const quote of quotes) handle.quoteReply(quote);
    return;
  }
  heldQuotes.current = [...quotes, ...(heldQuotes.current ?? [])];
}
