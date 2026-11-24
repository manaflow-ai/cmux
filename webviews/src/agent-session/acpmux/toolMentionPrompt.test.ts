// A sent prompt that names `@computer-use` or `@browser-use` (CMUX-682) reaches acpmux with the
// person's words as typed and the tool note as its hidden context (`_meta.acpmux.context`, which
// acpmux sends to the agent after the text and keeps out of the transcript). A prompt that names
// no tool carries no such note.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";

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
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Prompt = { prompt: { type: string; text?: string }[]; _meta?: { acpmux?: { context?: string } } };

test("a prompt naming a tool carries its note as hidden context; one naming none carries none", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const prompts: Prompt[] = [];
  // The mock acpmux, recording each prompt as it arrives.
  class RecordingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: unknown) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt") prompts.push(params as Prompt);
        return answer(method, params);
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new RecordingHost() as unknown as WebSocket,
  );
  try {
    await client.send("open the settings app with @computer-use", []);
    await client.send("check the page with @browser-use", []);
    await client.send("plain words, and `@computer-use` in code", []);
    expect(prompts).toHaveLength(3);
    const text = (prompt: Prompt) => prompt.prompt.map((block) => block.text ?? "").join("");
    const context = (prompt: Prompt) => prompt._meta?.acpmux?.context;
    // The person's words go as typed; the note goes beside them, never in them.
    expect(text(prompts[0]!)).toBe("open the settings app with @computer-use");
    expect(context(prompts[0]!)).toContain("<cmux-tools-context>");
    expect(context(prompts[0]!)).toContain("cmux Computer Use");
    expect(context(prompts[0]!)).not.toContain("cmux-browser");
    expect(context(prompts[1]!)).toContain("cmux-browser");
    expect(context(prompts[1]!)).not.toContain("cmux Computer Use");
    // Inside code it is literal text: no note.
    expect(context(prompts[2]!) ?? "").not.toContain("cmux-tools-context");
  } finally {
    client.close?.();
  }
});
