// The New Tab's first `/`: its menu lists the commands of a deferred chat of its agent. That chat
// started in a folder the pane had not been granted, so the relay refused it and the menu kept only
// cmux's own commands; and a chat that did start was read once, before the agent answered, so its
// skills never came. The page grants the folder first (newTabCommandsChat) and reads the chat's list
// again each time the chat publishes one (useSessionCommands `watch`).
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import type { SlashCommand } from "../slashCommands";
import { newTabCommandsChat } from "../startFolderModel";
import { useSessionCommands, type WatchSessionCommands } from "./useSessionCommands";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const skill = (name: string): SlashCommand => ({ name, description: "", source: "skill" });

test("a deferred chat's commands are read again each time it publishes a list", async () => {
  let published: (() => void) | undefined;
  const watch: WatchSessionCommands = (_sessionId, listener) => {
    published = listener;
    return () => {
      published = undefined;
    };
  };
  // The agent has not answered at the first read: an empty list. Its answer comes later.
  let list: SlashCommand[] = [];
  const reads: string[] = [];
  const read = async (sessionId: string) => {
    reads.push(sessionId);
    return list;
  };
  let shown: SlashCommand[] | undefined;
  function Probe() {
    shown = useSessionCommands("chat-1", undefined, read, watch);
    return null;
  }
  await act(async () => root!.render(<Probe />));
  expect(shown).toEqual([]);
  expect(published).toBeDefined();
  list = [skill("emil-color")];
  await act(async () => published!());
  expect(shown).toEqual([skill("emil-color")]);
  expect(reads).toEqual(["chat-1", "chat-1"]);
  // The watch ends with the hook.
  act(() => root!.unmount());
  root = undefined;
  expect(published).toBeUndefined();
});

test("the New Tab grants its folder before the chat that lists the commands starts there", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const host = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    // The host spells the folder its own way (a link resolved).
    if (method === "workspace.useFolder") return { status: "ok", cwd: "/Users/you/src/cmux" };
    return "chat-1";
  };
  await newTabCommandsChat(host, "claude", "/Users/you/cmux");
  expect(calls).toEqual([
    ["workspace.useFolder", { cwd: "/Users/you/cmux" }],
    ["chat.new", { harness: "claude", cwd: "/Users/you/src/cmux", deferred: true }],
  ]);
});

test("a folder the host asks about first starts the commands chat with no folder", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const host = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "workspace.useFolder") return { status: "confirm", reason: "home", cwd: "/Users/you" };
    return "chat-1";
  };
  await newTabCommandsChat(host, "claude", "/Users/you");
  expect(calls.at(-1)).toEqual(["chat.new", { harness: "claude", deferred: true }]);
  // No folder: nothing to grant.
  calls.length = 0;
  await newTabCommandsChat(host, "codex", undefined);
  expect(calls).toEqual([["chat.new", { harness: "codex", deferred: true }]]);
});
