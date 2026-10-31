import { expect, test } from "bun:test";
import { cloudPageRefusal, cloudStartToasted, oneCloudStart, startCloudChat } from "./cloudRun";

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
