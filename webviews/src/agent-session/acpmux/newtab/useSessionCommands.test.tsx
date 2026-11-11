import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { slashMenuEmptyLabel } from "../composerModel";
import type { SlashCommand } from "../slashCommands";
import { newTabCommandSnapshot, useSessionCommands } from "./useSessionCommands";

const review: SlashCommand = { name: "review", description: "", source: "agent" };
const label = (snapshot: ReturnType<typeof noChat>) => slashMenuEmptyLabel(snapshot.commands, snapshot.commandsPending);

test("New Tab's deferred chat: Loading commands… until its list is read, then its own list (M7)", () => {
  const page = noChat([], { commands: [{ name: "model", description: "", source: "cmux" }] });
  // Asked for, the chat not known yet: still loading, not "No commands".
  expect(label(newTabCommandSnapshot(page, undefined, undefined, true))).toBe("composer.loadingCommands");
  // The chat known, its list not read yet.
  expect(label(newTabCommandSnapshot(page, "deferred-1", undefined, true))).toBe("composer.loadingCommands");
  // Read empty, and read with a command.
  expect(label(newTabCommandSnapshot(page, "deferred-1", [], true))).toBe("composer.noCommands");
  expect(label(newTabCommandSnapshot(page, "deferred-1", [review], false))).toBe("composer.noMatchingCommands");
  // A page's own pending flag does not outlive the deferred chat's read.
  const pending = { ...page, commandsPending: true as const };
  expect(newTabCommandSnapshot(pending, "deferred-1", [], false).commandsPending).toBeUndefined();
  // Nothing asked: the page's snapshot as it is, the same object.
  expect(newTabCommandSnapshot(page, undefined, undefined, false)).toBe(page);
});

test("a deferred chat's command read that fails is read empty, never loading for good", async () => {
  const dom = new JSDOM("<!doctype html><main id=root></main>");
  const scope = globalThis as Record<string, unknown>;
  const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"] as const;
  const saved = new Map(keys.map((key) => [key, scope[key]]));
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  let root: Root | undefined;
  try {
    const seen: (SlashCommand[] | undefined)[] = [];
    const read = () => Promise.reject(new Error("no answer"));
    function Probe() {
      seen.push(useSessionCommands("deferred-1", undefined, read));
      return null;
    }
    root = createRoot(dom.window.document.getElementById("root")!);
    await act(async () => root!.render(<Probe />));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(seen[0]).toBeUndefined();
    expect(seen.at(-1)).toEqual([]);
  } finally {
    act(() => root?.unmount());
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
    dom.window.close();
  }
});
