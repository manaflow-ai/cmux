// l10n-allow-file: synthetic command names and descriptions.
// The composer's `/` list (SlashMenu.tsx), shared by New Tab and the agent chat. When a short
// window leaves it no room, its rows show in the host's native panel past the window's edge, one
// line of text per row (popupHost.ts popupItems). David Beyer (2026-11-20): the `/` menu on the main
// screen had a messy font and ran over the screen's edge. Each row there read as its parts run
// together ("/modelcmuxModel", "/customize<change>cmuxCustomize cmux by asking"). A row's line
// must read as the command, then its arguments, then a dash and what it does.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { popupItems } from "../../ui/popupHost";
import { SlashMenu } from "./SlashMenu";
import type { SlashMatch } from "./slashCommands";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const MATCHES: SlashMatch[] = [
  { command: { name: "compact", description: "Clear conversation history but keep a summary" }, ranges: [] },
  { command: { name: "model", description: "Model", source: "cmux" }, ranges: [] },
  {
    command: {
      name: "customize",
      hint: "<change>",
      source: "cmux",
      description: "Customize cmux by asking: it changes live, then you apply or discard",
    },
    ranges: [[0, 4]],
  },
  { command: { name: "review", description: "Review a pull request", source: "skill" }, ranges: [] },
];

test("each row reads as command, arguments, then a dash and what it does in the native panel", async () => {
  const host = installDom();
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <SlashMenu matches={MATCHES} active={0} empty="No commands" onHover={() => undefined} onPick={() => undefined} />,
    );
  });
  const list = dom!.window.document.querySelector("#acpmux-slash-menu")!;
  expect(list).not.toBeNull();
  const labels = popupItems(list, "list").items.map((item) => item.label);
  expect(labels).toEqual([
    "/compact — Clear conversation history but keep a summary",
    "/model — Model",
    "/customize <change> — Customize cmux by asking: it changes live, then you apply or discard",
    "/review — Review a pull request",
  ]);
});
