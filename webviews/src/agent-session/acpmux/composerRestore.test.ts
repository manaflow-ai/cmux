import { expect, test } from "bun:test";
import type { ComposerAttachment } from "./attachments";
import { restoreComposerDraft } from "./composerRestore";

test("queued edit restore survives an unmount before removal resolves and remounts once", async () => {
  const restored: [string, ComposerAttachment[]][] = [];
  const composer = {
    current: null as { restore(text: string, attachments: ComposerAttachment[]): void } | null,
  };
  const heldBack = { current: undefined as { text: string; attachments: ComposerAttachment[] }[] | undefined };
  const attachments: ComposerAttachment[] = [
    {
      id: "image-1",
      kind: "image",
      name: "notes.png",
      mimeType: "image/png",
      size: 12,
      data: "aGVsbG8=",
    },
  ];
  let resolveRemoval!: (removed: boolean) => void;
  const removal = new Promise<boolean>((resolve) => {
    resolveRemoval = resolve;
  });

  const edit = (async () => {
    const removed = await removal;
    if (removed) restoreComposerDraft(composer, heldBack, "queued text", attachments);
    return removed;
  })();

  // SandboxedRun replaces the composer while the queue removal is in flight.
  composer.current = null;
  resolveRemoval(true);
  expect(await edit).toBe(true);
  expect(heldBack.current).toEqual([{ text: "queued text", attachments }]);

  // The composer remount flushes the held prompt exactly once, retaining its image bytes.
  composer.current = {
    restore: (text, nextAttachments) => restored.push([text, nextAttachments]),
  };
  const waiting = heldBack.current;
  heldBack.current = undefined;
  const mounted = composer.current;
  if (!mounted) throw new Error("composer did not remount");
  for (const prompt of waiting ?? []) mounted.restore(prompt.text, prompt.attachments);

  expect(restored).toEqual([["queued text", attachments]]);
  expect(heldBack.current).toBeUndefined();
});

// Quote in Reply while the composer is unmounted (a Sandboxed receipt opened, then Back): the quote
// used to be dropped, because only a mounted composer took `chat.quoteReply`.
type Calls = (["restore", string] | ["quote", string])[];
function composer(calls: Calls) {
  return {
    restore: (text: string) => calls.push(["restore", text]),
    quoteReply: (markdown: string) => calls.push(["quote", markdown]),
  };
}

test("a quote picked while the composer is unmounted replays once when it mounts", async () => {
  const { quoteIntoComposer, replayHeldForComposer } = await import("./composerRestore");
  const calls: Calls = [];
  const handle = { current: null as ReturnType<typeof composer> | null };
  const heldBack = { current: undefined as { text: string; attachments: ComposerAttachment[] }[] | undefined };
  const heldQuotes = { current: undefined as string[] | undefined };

  quoteIntoComposer(handle, heldQuotes, "> Selected line\n\n");
  expect(calls).toEqual([]);
  expect(heldQuotes.current).toEqual(["> Selected line\n\n"]);

  handle.current = composer(calls);
  replayHeldForComposer(handle.current, heldBack, heldQuotes);
  expect(calls).toEqual([["quote", "> Selected line\n\n"]]);
  expect(heldQuotes.current).toBeUndefined();

  // Another mount (Back, then the receipt and Back again) replays nothing a second time.
  replayHeldForComposer(handle.current, heldBack, heldQuotes);
  expect(calls).toEqual([["quote", "> Selected line\n\n"]]);
});

test("two quotes while unmounted replay in order, after a held-back prompt", async () => {
  const { quoteIntoComposer, replayHeldForComposer } = await import("./composerRestore");
  const calls: Calls = [];
  const handle = { current: null as ReturnType<typeof composer> | null };
  const heldBack = { current: undefined as { text: string; attachments: ComposerAttachment[] }[] | undefined };
  const heldQuotes = { current: undefined as string[] | undefined };

  quoteIntoComposer(handle, heldQuotes, "> First\n\n");
  restoreComposerDraft(handle, heldBack, "refused prompt", []);
  quoteIntoComposer(handle, heldQuotes, "> Second\n\n");
  replayHeldForComposer(null, heldBack, heldQuotes);
  expect(calls).toEqual([]);

  handle.current = composer(calls);
  replayHeldForComposer(handle.current, heldBack, heldQuotes);
  expect(calls).toEqual([
    ["restore", "refused prompt"],
    ["quote", "> First\n\n"],
    ["quote", "> Second\n\n"],
  ]);
  expect(heldBack.current).toBeUndefined();
  expect(heldQuotes.current).toBeUndefined();
});

test("a quote while the composer is mounted goes straight in", async () => {
  const { quoteIntoComposer } = await import("./composerRestore");
  const calls: Calls = [];
  const heldQuotes = { current: undefined as string[] | undefined };
  quoteIntoComposer({ current: composer(calls) }, heldQuotes, "> Now\n\n");
  expect(calls).toEqual([["quote", "> Now\n\n"]]);
  expect(heldQuotes.current).toBeUndefined();
});

test("quotes a composer hands back wait ahead of later ones, or go straight into a live composer", async () => {
  const { handBackQuotes, quoteIntoComposer, replayHeldForComposer } = await import("./composerRestore");
  const calls: Calls = [];
  const handle = { current: null as ReturnType<typeof composer> | null };
  const heldBack = { current: undefined as { text: string; attachments: ComposerAttachment[] }[] | undefined };
  const heldQuotes = { current: undefined as string[] | undefined };

  quoteIntoComposer(handle, heldQuotes, "> Later\n\n");
  handBackQuotes(handle, heldQuotes, ["> Earlier\n\n"]);
  expect(heldQuotes.current).toEqual(["> Earlier\n\n", "> Later\n\n"]);

  handle.current = composer(calls);
  replayHeldForComposer(handle.current, heldBack, heldQuotes);
  handBackQuotes(handle, heldQuotes, ["> Straight in\n\n"]);
  handBackQuotes(handle, heldQuotes, []);
  expect(calls).toEqual([
    ["quote", "> Earlier\n\n"],
    ["quote", "> Later\n\n"],
    ["quote", "> Straight in\n\n"],
  ]);
  expect(heldQuotes.current).toBeUndefined();
});
