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
