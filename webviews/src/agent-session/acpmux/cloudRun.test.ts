import { expect, test } from "bun:test";
import { inlineToken, promptBlocks, type ComposerAttachment } from "./attachments";
import type { AcpmuxHostConfig } from "./direct";
import {
  cloudPageRefusal,
  cloudRunsHere,
  cloudStartFolder,
  cloudStartKeys,
  cloudStartToasted,
  newTabProjectPick,
  oneCloudStart,
  startCloudChat,
} from "./cloudRun";

test("a Cloud start sends the prompt, folder, agent and model with a key, and answers ok", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const answer = await startCloudChat(
    async (method, params) => (calls.push([method, params]), { machine: "cloud-1" }),
    { task: "fix it", cwd: "/Users/me/paint", harness: "codex", model: "gpt-6-astra" },
    "00000000-0000-4000-8000-000000000001",
  );
  expect(answer).toEqual({ ok: true });
  expect(calls).toEqual([
    [
      "cloud.startChat",
      {
        task: "fix it",
        cwd: "/Users/me/paint",
        harness: "codex",
        model: "gpt-6-astra",
        key: "00000000-0000-4000-8000-000000000001",
      },
    ],
  ]);
});

test("a refusal keeps its code and the host's words; only a start the host ran was toasted", async () => {
  const failed = await startCloudChat(
    async () => Promise.reject({ code: "cloud_start_failed", userMessage: "Could not copy the folder." }),
    { task: "t" },
  );
  expect(failed).toEqual({ ok: false, code: "cloud_start_failed", message: "Could not copy the folder." });
  expect(cloudStartToasted(failed)).toBe(true);
  expect(cloudStartToasted({ ok: false, code: "cloud_plan_required" })).toBe(true);
  const off = await startCloudChat(async () => Promise.reject({ code: "not_signed_in" }), { task: "t" });
  expect(cloudStartToasted(off)).toBe(false);
  const lost = await startCloudChat(async () => Promise.reject(new Error("bridge gone")), { task: "t" });
  expect(lost.ok).toBe(false);
});

test("Run on This Mac from the cap card is no toasted failure: the page sends the prompt here", async () => {
  const here = await startCloudChat(async () => Promise.reject({ code: "run_on_this_mac" }), { task: "t" });
  expect(here).toMatchObject({ ok: false, code: "run_on_this_mac" });
  expect(cloudRunsHere(here)).toBe(true);
  expect(cloudStartToasted(here)).toBe(false);
  const failed = await startCloudChat(async () => Promise.reject({ code: "cloud_start_failed" }), { task: "t" });
  expect(cloudRunsHere(failed)).toBe(false);
  expect(cloudRunsHere({ ok: true })).toBe(false);
});

test("a Cloud first send carries attachment contents and inline ids for the destination's ordinary send", async () => {
  const attachments: ComposerAttachment[] = [
    {
      id: "image",
      kind: "image",
      name: "reference.png",
      mimeType: "image/png",
      size: 3,
      data: "AQID",
      inline: true,
      originalPath: "/Users/me/reference.png",
      originalName: "reference.png",
      source: { name: "Screenshot", bundleId: "com.apple.screencaptureui" },
    },
    {
      id: "paste",
      kind: "pasted",
      name: "notes.txt",
      mimeType: "text/plain",
      size: 5,
      text: "notes",
      inline: true,
    },
    { id: "pdf", kind: "document", name: "plan.pdf", mimeType: "application/pdf", size: 3, data: "BAUG", pageCount: 2 },
    { id: "audio", kind: "audio", name: "voice.wav", mimeType: "audio/wav", size: 3, data: "BwgJ" },
    { id: "text", kind: "text", name: "task.txt", mimeType: "text/plain", size: 4, text: "task" },
  ];
  const task = `before${inlineToken("image")}middle${inlineToken("paste")}after`;
  let sent!: { task: string; attachments: ComposerAttachment[] };
  await startCloudChat(
    async (_method, params) => {
      sent = JSON.parse(JSON.stringify(params));
      return {};
    },
    { task, attachments, home: true, harness: "claude" },
  );
  expect(sent.task).toBe(task);
  expect(sent.attachments).toEqual(attachments);

  // The native upload remaps file references before the destination receives its ready seed.
  const remoteImage = "/home/cmux/chat/attachments/reference.png";
  const host: AcpmuxHostConfig = {
    protocolVersion: 2,
    transport: "acpmux-bridge",
    prompt: sent.task,
    promptAttachments: sent.attachments.map((chip) =>
      chip.id === "image" ? { ...chip, originalPath: remoteImage } : chip,
    ),
  };
  const blocks = promptBlocks(host.prompt ?? "", host.promptAttachments ?? []);
  expect(blocks.map((block) => block.type)).toEqual([
    "text",
    "image",
    "resource_link",
    "text",
    "text",
    "text",
    "document",
    "audio",
    "text",
  ]);
  expect(blocks.slice(0, 6)).toEqual([
    { type: "text", text: "before" },
    { type: "image", mimeType: "image/png", data: "AQID", name: "reference.png" },
    { type: "resource_link", uri: `file://${remoteImage}`, name: "reference.png" },
    { type: "text", text: "middle" },
    { type: "text", text: "notes", _meta: { cmux: { pasted: true } } },
    { type: "text", text: "after" },
  ]);
  expect(blocks[6]).toEqual({ type: "document", mimeType: "application/pdf", data: "BAUG", name: "plan.pdf" });
  expect(blocks[7]).toEqual({ type: "audio", mimeType: "audio/wav", data: "BwgJ" });
  expect(blocks[8]).toMatchObject({ type: "text", text: expect.stringContaining("task.txt") });
});

test("an attachment-only Cloud send preserves its empty task and image bytes", async () => {
  const attachments: ComposerAttachment[] = [
    { id: "image", kind: "image", name: "image.png", mimeType: "image/png", size: 3, data: "AQID" },
  ];
  const calls: Record<string, unknown>[] = [];
  expect(
    await startCloudChat(async (_method, params) => (calls.push(params), {}), { task: "", attachments, home: true }),
  ).toEqual({ ok: true });
  expect(calls[0]).toMatchObject({ task: "", attachments });
  expect(promptBlocks("", attachments)).toEqual([
    { type: "image", mimeType: "image/png", data: "AQID", name: "image.png" },
  ]);
  expect(cloudPageRefusal(true)).toBeUndefined();
});

test("Cloud picked but no longer offered refuses the send, never sending it as a chat here", () => {
  expect(cloudPageRefusal(false)).toBe("cloud_not_now");
});

test("a second Return while a start waits on the host starts nothing; after the answer one may start again", async () => {
  const calls: string[] = [];
  let answer!: () => void;
  const start = oneCloudStart((_, params) => {
    calls.push(params.task as string);
    return new Promise<void>((resolve) => (answer = resolve));
  });
  const first = start({ task: "one" });
  expect(first).toBeDefined();
  expect(start({ task: "two" })).toBeUndefined();
  answer();
  expect(await first).toEqual({ ok: true });
  expect(start({ task: "three" })).toBeDefined();
  expect(calls).toEqual(["one", "three"]);
});

test("a Cloud chat copies its project; with none (or home) it starts in the machine's own folder", () => {
  expect(cloudStartFolder("/Users/me/src/paint")).toEqual({ cwd: "/Users/me/src/paint" });
  expect(cloudStartFolder("/Users/me/src/paint/")).toEqual({ cwd: "/Users/me/src/paint" });
  for (const none of [undefined, "", "relative/path", "/", "/Users", "/Users/me", "/Users/me/", "/home/me"])
    expect(cloudStartFolder(none)).toEqual({ home: true });
  // A no-project chat's private agent-home folder is never copied.
  expect(cloudStartFolder("/Users/me/Library/Application Support/cmux/agent-home/abc123")).toEqual({ home: true });
});

test("a start with no project tells the host home, and never names a folder", async () => {
  const calls: Record<string, unknown>[] = [];
  await startCloudChat(
    async (_method, params) => (calls.push(params), {}),
    { task: "hi", home: true, harness: "claude" },
    "00000000-0000-4000-8000-000000000002",
  );
  expect(calls).toEqual([{ task: "hi", home: true, harness: "claude", key: "00000000-0000-4000-8000-000000000002" }]);
});

test("a New Tab project picked before the host's sandbox check still reaches workspace.useFolder", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const native = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    return { status: "ok" };
  };
  // `offerable` is the Cloud offer without `sandbox.checked`: the pick is wired while that check is out.
  const { onProjectPicked } = newTabProjectPick(native, true);
  expect(onProjectPicked).toBeDefined();
  onProjectPicked!("/Users/me/src/paint");
  await Promise.resolve();
  expect(calls).toEqual([["workspace.useFolder", { cwd: "/Users/me/src/paint" }]]);
  // Home or above is never copied, so it asks the host nothing here.
  onProjectPicked!("/Users/me");
  await Promise.resolve();
  expect(calls).toHaveLength(1);
  // Not offered (a chat started here, the Quick Composer): nothing is wired.
  expect(newTabProjectPick(native, false)).toEqual({});
});

test("the chosen Cloud environment travels with the start; an absent choice preserves the platform Default", async () => {
  const calls: Record<string, unknown>[] = [];
  const call = async (_method: string, params: Record<string, unknown>) => {
    calls.push(params);
    return {};
  };
  await startCloudChat(call, { task: "hello", home: true, environment: "env_selected" }, "selected-start");
  await startCloudChat(call, { task: "hello", home: true }, "default-start");
  expect(calls[0]?.environment).toBe("env_selected");
  expect(calls[1]).not.toHaveProperty("environment");
});

/// A `localStorage` stand-in that outlives one page's `cloudStartKeys` (a page reload makes a new one).
function memoryStore() {
  const items = new Map<string, string>();
  return {
    getItem: (name: string) => items.get(name) ?? null,
    setItem: (name: string, value: string) => void items.set(name, value),
  };
}

function counter() {
  let count = 0;
  return () => `00000000-0000-4000-8000-${String(++count).padStart(12, "0")}`;
}

test("a retry of a start whose answer was lost sends the first key again, so the host makes no second machine (#33493)", async () => {
  const sent: unknown[] = [];
  const call = async (_method: string, params: Record<string, unknown>) => {
    sent.push(params.key);
    // The create answer is lost: the host's start ended without a chat.
    return Promise.reject({ code: "unavailable" });
  };
  const keys = cloudStartKeys(memoryStore(), () => 1_000, counter());
  const start = { task: "fix it", cwd: "/Users/me/paint", harness: "codex" };
  for (let attempt = 0; attempt < 3; attempt++) {
    const key = keys.keyFor(start);
    keys.ended(start, await startCloudChat(call, start, key));
  }
  expect(sent).toEqual([
    "00000000-0000-4000-8000-000000000001",
    "00000000-0000-4000-8000-000000000001",
    "00000000-0000-4000-8000-000000000001",
  ]);
});

test("a start's key outlives a page reload while its answer is out, and is new once it opened a chat", () => {
  const store = memoryStore();
  const next = counter();
  const start = { task: "fix it", cwd: "/Users/me/paint" };
  const first = cloudStartKeys(store, () => 1_000, next).keyFor(start);
  // The page reloaded mid-create: a new page, the same prompt sent again.
  const again = cloudStartKeys(store, () => 2_000, next);
  expect(again.keyFor(start)).toBe(first);
  again.ended(start, { ok: true });
  expect(again.keyFor(start)).not.toBe(first);
});

test("the cap card's Run on This Mac ends the start; a changed prompt, folder or agent is a new start", () => {
  const keys = cloudStartKeys(memoryStore(), () => 1_000, counter());
  const start = { task: "fix it", cwd: "/Users/me/paint", harness: "codex" };
  const first = keys.keyFor(start);
  expect(keys.keyFor({ ...start, task: "fix it now" })).not.toBe(first);
  expect(keys.keyFor({ ...start, cwd: "/Users/me/other" })).not.toBe(first);
  expect(keys.keyFor({ ...start, harness: "claude" })).not.toBe(first);
  expect(keys.keyFor(start)).toBe(first);
  keys.ended(start, { ok: false, code: "run_on_this_mac" });
  expect(keys.keyFor(start)).not.toBe(first);
});

test("a kept key expires after a day, and a store that refuses writes still dedupes this page's retries", () => {
  let now = 1_000;
  const store = memoryStore();
  const next = counter();
  const keys = cloudStartKeys(store, () => now, next);
  const start = { task: "t", home: true };
  const first = keys.keyFor(start);
  now += 25 * 60 * 60 * 1000;
  expect(cloudStartKeys(store, () => now, next).keyFor(start)).not.toBe(first);

  const refusing = cloudStartKeys(
    {
      getItem: () => null,
      setItem: () => {
        throw new Error("QuotaExceededError");
      },
    },
    () => 1_000,
    counter(),
  );
  expect(refusing.keyFor(start)).toBe(refusing.keyFor(start));
});

test("the stored entry names the start by a hash, never its prompt", () => {
  const store = memoryStore();
  cloudStartKeys(store, () => 1_000, counter()).keyFor({ task: "my secret plan", cwd: "/Users/me/paint" });
  const saved = store.getItem("cmux.cloudStart.keys") ?? "";
  expect(saved).not.toContain("secret");
  expect(saved).not.toContain("paint");
});
