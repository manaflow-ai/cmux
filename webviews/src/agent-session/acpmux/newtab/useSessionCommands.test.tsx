// The New Tab's `/` menu lists the commands of a deferred chat of its agent. That chat was read once,
// before the agent answered (its start takes seconds), so its skills never came. The page reads the
// chat's list again each time the chat publishes one (useSessionCommands `watch`), and watches again
// on a new client (a reconnect).
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import type { SlashCommand } from "../slashCommands";
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

test("a new watch (a reconnect's client) replaces the old one", async () => {
  const live = new Set<string>();
  const watchOn =
    (client: string): WatchSessionCommands =>
    (sessionId) => {
      live.add(`${client}:${sessionId}`);
      return () => live.delete(`${client}:${sessionId}`);
    };
  const read = async () => [] as SlashCommand[];
  function Probe({ watch }: { watch: WatchSessionCommands }) {
    useSessionCommands("chat-1", undefined, read, watch);
    return null;
  }
  const first = watchOn("first");
  await act(async () => root!.render(<Probe watch={first} />));
  expect([...live]).toEqual(["first:chat-1"]);
  await act(async () => root!.render(<Probe watch={watchOn("second")} />));
  expect([...live]).toEqual(["second:chat-1"]);
});
