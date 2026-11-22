import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { session } from "../../gallery/fixtures/acpmux";
import { settleReact } from "../../../test/support/domTeardown";
import { HomeLists } from "./HomeLists";
import { AgentDotGrid } from "./dotGrid/AgentDotGrid";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
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

for (const kind of ["lists", "dots"] as const) {
  test(`${kind} reports rendered content, ignores filtered chats, and clears on removal`, async () => {
    const container = installDom();
    root = createRoot(container);
    const presence = jest.fn();
    const review = session({
      sessionId: "review",
      pullRequest: { number: 1, title: "Ready", state: "open", reviewReady: true },
    });
    const draw = (sessions: ReturnType<typeof session>[]) =>
      kind === "lists" ? (
        <HomeLists sessions={sessions} onSelect={() => {}} onAnswer={async () => "answered"} onPresence={presence} />
      ) : (
        <AgentDotGrid sessions={sessions} onSelect={() => {}} onPresence={presence} />
      );
    await act(async () => root!.render(draw([{ ...review, archived: true }])));
    expect(container.children).toHaveLength(0);
    expect(presence).toHaveBeenLastCalledWith(false);
    await act(async () => root!.render(draw([review])));
    expect(container.children.length).toBeGreaterThan(0);
    expect(presence).toHaveBeenLastCalledWith(true);
    const reports = presence.mock.calls.length;
    await act(async () => root!.render(draw([{ ...review, displayTitle: "Updated title" }])));
    expect(presence.mock.calls).toHaveLength(reports);
    await act(async () => root!.render(draw([])));
    expect(container.children).toHaveLength(0);
    expect(presence).toHaveBeenLastCalledWith(false);
    await act(async () => root!.render(draw([review])));
    expect(presence).toHaveBeenLastCalledWith(true);
    await act(async () => root!.render(null));
    expect(presence).toHaveBeenLastCalledWith(false);
  });
}
