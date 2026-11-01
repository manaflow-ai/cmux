import { expect, test } from "bun:test";
import {
  cloudPageRefusal,
  cloudStartFolder,
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
  const off = await startCloudChat(async () => Promise.reject({ code: "not_signed_in" }), { task: "t" });
  expect(cloudStartToasted(off)).toBe(false);
  const lost = await startCloudChat(async () => Promise.reject(new Error("bridge gone")), { task: "t" });
  expect(lost.ok).toBe(false);
});

test("a Cloud chat takes text only for now", () => {
  expect(cloudPageRefusal(true, 0)).toBeUndefined();
  expect(cloudPageRefusal(true, 2)).toBe("cloud_attachments");
});

test("Cloud picked but no longer offered refuses the send, never sending it as a chat here", () => {
  expect(cloudPageRefusal(false, 0)).toBe("cloud_not_now");
  expect(cloudPageRefusal(false, 2)).toBe("cloud_not_now");
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
