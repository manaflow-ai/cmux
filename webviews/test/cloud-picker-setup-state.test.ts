// cmux#51731: with Cloud picked, Claude Code and Codex are pickable once a connection serves their family on
// Cloud (`cloud.setupState`); the rest list as signed out with Cloud's own set up button. OpenCode and pi need none.
import { expect, test } from "bun:test";
import {
  cloudFamilyOf,
  cloudSetUpAction,
  cloudSignedOut,
  readCloudFamilies,
} from "../src/agent-session/acpmux/cloudPickerEntries";

const entry = (id: string) => ({ id, name: id, models: [] }) as never;

test("a family Cloud does not serve lists as signed out; one it serves, or one unread, does not", () => {
  const entries = [entry("claude"), entry("codex"), entry("opencode"), entry("pi")];
  expect(cloudSignedOut(entries, { claude: true, codex: false })).toEqual({ codex: "codex" });
  expect(cloudSignedOut(entries, { claude: false, codex: false })).toEqual({ claude: "claude", codex: "codex" });
  expect(cloudSignedOut(entries, {})).toEqual({});
  expect(cloudFamilyOf("opencode")).toBeUndefined();
});

test("each family's button runs its own way in", () => {
  expect(cloudSetUpAction("claude")).toBe("setUpClaude");
  expect(cloudSetUpAction("codex")).toBe("connectChatGPT");
});

test("the host's answer is read family by family, and a failure holds nothing back", async () => {
  const calls: string[] = [];
  const read = await readCloudFamilies(async (method) => {
    calls.push(method);
    return { families: { claude: true, codex: false, gemini: true } };
  });
  expect(calls).toEqual(["cloud.setupState"]);
  expect(read).toEqual({ claude: true, codex: false });
  expect(await readCloudFamilies(async () => ({}))).toEqual({});
  expect(
    await readCloudFamilies(async () => {
      throw new Error("unknown_op");
    }),
  ).toEqual({});
});
