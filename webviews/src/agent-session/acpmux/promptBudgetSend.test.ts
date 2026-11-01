// A prompt with a dozen screenshots went to acpmux as one message over its 15 MiB limit and was
// refused as message.too_large (Leo, 2026-10-31: "this is completely hardlocked bc of message
// size"). The client sends the largest previews as their originals' links, and the sent bubble
// shows those as files: none of the screenshots disappears from it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { ComposerAttachment, PromptBlock } from "./attachments";
import { PROMPT_INLINE_BUDGET, inlineBytes } from "./promptBudget";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const MIB = 1024 * 1024;
const screenshot = (index: number): ComposerAttachment => ({
  id: `shot-${index}`,
  kind: "image",
  name: `Screenshot ${index}.png`,
  mimeType: "image/png",
  size: 1.5 * MIB,
  data: "A".repeat(2 * MIB),
  originalPath: `/Users/me/.cmux/uploads/Screenshot ${index}.png`,
  originalName: `Screenshot ${index}.png`,
});

type Row = { kind: string; images?: unknown[]; retryAttachments?: ComposerAttachment[] };

test("a dozen screenshots go in one message under the budget, and the bubble keeps every one", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const prompts: PromptBlock[][] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt") prompts.push(params.prompt as PromptBlock[]);
        return answer(method, params);
      };
    }
  }
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  try {
    const shots = Array.from({ length: 12 }, (_, index) => screenshot(index));
    await client.send("look at these", shots).catch(() => undefined);
    const blocks = prompts.at(-1)!;
    expect(inlineBytes(blocks)).toBeLessThanOrEqual(PROMPT_INLINE_BUDGET);
    const links = blocks.filter((block) => block.type === "resource_link");
    // Every screenshot's original still goes.
    expect(links).toHaveLength(12);
    const previews = blocks.filter((block) => block.type === "image").length;
    expect(previews).toBeGreaterThan(0);
    expect(previews).toBeLessThan(12);
    // The bubble: each screenshot is drawn as its image, or as its original's file link.
    const bubble = rows.find((row) => row.kind === "user" && row.retryAttachments?.length);
    const kept = bubble?.retryAttachments ?? [];
    expect(kept).toHaveLength(12);
    const images = kept.filter((chip) => chip.kind === "image");
    const files = kept.filter((chip) => chip.kind === "link" && chip.path?.endsWith(".png"));
    expect(images).toHaveLength(previews);
    expect(files).toHaveLength(12 - previews);
    expect(bubble?.images).toHaveLength(previews);
  } finally {
    client.close?.();
  }
});
