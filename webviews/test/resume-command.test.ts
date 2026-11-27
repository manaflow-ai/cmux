import { expect, test } from "bun:test";
import { CmuxCommandRefused, composerCommand } from "../src/agent-session/acpmux/cmuxCommands";
import { runResume } from "../src/agent-session/acpmux/resumeCommand";

const ID = "920ab030-d857-4a26-8afb-574eb70e8b2c";
const t = (key: string, values?: Record<string, string | number>) => `${key}:${values?.ref ?? ""}`;

function host(reply: unknown) {
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  let searched = 0;
  return {
    calls,
    searched: () => searched,
    callNative: (method: string, params?: Record<string, unknown>) => {
      calls.push({ method, params });
      return reply instanceof Error ? Promise.reject(reply) : Promise.resolve(reply);
    },
    showAllChats: () => {
      searched += 1;
    },
  };
}

test("/resume with a pasted session id asks the app to resume that chat, not the chats search", async () => {
  const command = composerCommand(`/resume ${ID}`, "claude");
  if (command?.kind !== "cmux") throw new Error("/resume is not cmux's");
  expect(command.command.action).toBe("resume");
  const app = host({ status: "opened" });
  await runResume(command.args, app.callNative, app.showAllChats, t as never);
  expect(app.calls).toEqual([{ method: "chats.resume", params: { ref: ID } }]);
  expect(app.searched()).toBe(0);
});

test("a bare /resume still opens the chats search", () => {
  const app = host({ status: "opened" });
  expect(runResume("  ", app.callNative, app.showAllChats, t as never)).toBe(true);
  expect(app.searched()).toBe(1);
  expect(app.calls).toEqual([]);
});

test("a reference no chat has, or several share, is refused inline with the reason", async () => {
  for (const [status, key] of [
    ["notFound", "composer.cmuxResumeNotFound"],
    ["ambiguous", "composer.cmuxResumeAmbiguous"],
    ["tooShort", "composer.cmuxResumeTooShort"],
    ["somethingNew", "composer.cmuxResumeUnavailable"],
  ] as const) {
    const app = host({ status });
    const run = runResume("920a", app.callNative, app.showAllChats, t as never);
    await expect(run as Promise<void>).rejects.toBeInstanceOf(CmuxCommandRefused);
    await expect(run as Promise<void>).rejects.toThrow(`${key}:920a`);
  }
  const app = host(new Error("unsupported"));
  await expect(
    runResume(
      `/Users/me/.claude/projects/p/${ID}.jsonl`,
      app.callNative,
      app.showAllChats,
      t as never,
    ) as Promise<void>,
  ).rejects.toThrow(`composer.cmuxResumeUnavailable:${ID}.jsonl`);
});
