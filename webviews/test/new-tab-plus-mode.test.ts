// The New Tab + menu's Plan/Build row (newtab/plusActions.ts) reaches the host the way the page's
// mode chip does (App `DefaultComposerChips`): the deferred start for the picked harness and folder
// goes first, then the mode, which the switch holds until that chat starts (harnessSwitch.pickMode).
import { expect, test } from "bun:test";
import { newTabScreenActions } from "../src/agent-session/acpmux/newtab/screenActions";

function host(options: { started?: boolean; refuseMode?: boolean } = {}) {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push([method, params]);
      if (method === "chat.mode" && options.refuseMode) throw new Error("refused");
      return undefined;
    },
    leave() {},
    selectSession() {},
    showAllChats() {},
    runShell() {},
    chatStarted: () => options.started === true,
  });
  return { actions, calls };
}

test("a Plan pick starts the page's deferred chat for the picked harness and folder, then sets the mode", async () => {
  const { actions, calls } = host();
  await actions.onPlusMode?.({ harness: "claude", cwd: "/work/app", model: "opus", modeId: "plan" });
  expect(calls).toEqual([
    ["chat.new", { harness: "claude", cwd: "/work/app", model: "opus", deferred: true }],
    ["chat.mode", { modeId: "plan" }],
  ]);
});

test("a chat that already started takes only the mode", async () => {
  const { actions, calls } = host({ started: true });
  await actions.onPlusMode?.({ harness: "claude", cwd: "/work/app", modeId: "default" });
  expect(calls).toEqual([["chat.mode", { modeId: "default" }]]);
});

test("another machine or no project has no deferred start: chat.new would open the chat itself", async () => {
  for (const pick of [
    { harness: "codex", peer: "mini-2", modeId: "plan" },
    { harness: "codex", noProject: true as const, modeId: "plan" },
  ]) {
    const { actions, calls } = host();
    await actions.onPlusMode?.(pick);
    expect(calls).toEqual([["chat.mode", { modeId: "plan" }]]);
  }
});

test("a refused mode rejects, so the menu stays open with its error", async () => {
  const { actions } = host({ refuseMode: true });
  await expect(actions.onPlusMode?.({ harness: "claude", modeId: "plan" }) ?? Promise.resolve()).rejects.toThrow(
    "refused",
  );
});
