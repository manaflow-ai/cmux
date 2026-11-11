import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { slashMenuEmptyLabel } from "../composerModel";
import type { SlashCommand } from "../slashCommands";
import { newTabCommandSnapshot, useSessionCommands, type SessionCommands } from "./useSessionCommands";

const review: SlashCommand = { name: "review", description: "", source: "agent" };
const label = (snapshot: ReturnType<typeof noChat>) =>
  slashMenuEmptyLabel(snapshot.commands, snapshot.commandsPending, snapshot.commandsFailed);
const read = (commands: SlashCommand[] | undefined, failed = false) => ({ commands, failed });

test("New Tab's deferred chat: Loading commands… until its list is read, then its own list (M7)", () => {
  const page = noChat([], { commands: [{ name: "model", description: "", source: "cmux" }] });
  // Asked for, the chat not known yet: still loading, not "No commands".
  expect(label(newTabCommandSnapshot(page, undefined, read(undefined), "asked"))).toBe("composer.loadingCommands");
  // The chat known, its list not read yet.
  expect(label(newTabCommandSnapshot(page, "deferred-1", read(undefined), "asked"))).toBe("composer.loadingCommands");
  // Read empty, and read with a command.
  expect(label(newTabCommandSnapshot(page, "deferred-1", read([]), "asked"))).toBe("composer.noCommands");
  expect(label(newTabCommandSnapshot(page, "deferred-1", read([review]), undefined))).toBe(
    "composer.noMatchingCommands",
  );
  // A page's own pending flag does not outlive the deferred chat's read.
  const pending = { ...page, commandsPending: true as const };
  expect(newTabCommandSnapshot(pending, "deferred-1", read([]), undefined).commandsPending).toBeUndefined();
  // Nothing asked: the page's snapshot as it is, the same object.
  expect(newTabCommandSnapshot(page, undefined, read(undefined), undefined)).toBe(page);
});

// Round 4 (verifier M7): a refused ask, or a deferred chat's read that failed, fell back to an
// empty list ("No commands"). Both are failures with Try Again.
test("New Tab: a refused ask or a failed read is Couldn't load commands., never No commands (M7)", () => {
  const page = noChat([], { commands: [{ name: "model", description: "", source: "cmux" }] });
  const refused = newTabCommandSnapshot(page, undefined, read(undefined), "failed");
  expect(refused.commandsFailed).toBe(true);
  expect(label(refused)).toBe("composer.loadCommandsFailed");
  const failed = newTabCommandSnapshot(page, "deferred-1", read(undefined, true), "asked");
  expect(failed.commandsPending).toBeUndefined();
  expect(label(failed)).toBe("composer.loadCommandsFailed");
  // A list read wins over a failed re-read's flag.
  expect(label(newTabCommandSnapshot(page, "deferred-1", read([review], true), undefined))).toBe(
    "composer.noMatchingCommands",
  );
});

// Round 4 (verifier M7): the hook read a failed read as an empty list. It reports the failure;
// its retry reads again (loading meanwhile), and the list it finds replaces the failure.
test("a deferred chat's command read that fails is a failure, and Try Again reads again", async () => {
  const dom = new JSDOM("<!doctype html><main id=root></main>");
  const scope = globalThis as Record<string, unknown>;
  const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"] as const;
  const saved = new Map(keys.map((key) => [key, scope[key]]));
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  let root: Root | undefined;
  try {
    const seen: SessionCommands[] = [];
    let calls = 0;
    const readCommands = () => (++calls === 1 ? Promise.reject(new Error("no answer")) : Promise.resolve([review]));
    function Probe() {
      seen.push(useSessionCommands("deferred-1", undefined, readCommands));
      return null;
    }
    root = createRoot(dom.window.document.getElementById("root")!);
    await act(async () => root!.render(<Probe />));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(seen[0]!.commands).toBeUndefined();
    expect(seen[0]!.failed).toBe(false);
    expect(seen.at(-1)!.commands).toBeUndefined();
    expect(seen.at(-1)!.failed).toBe(true);
    await act(async () => seen.at(-1)!.retry());
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(calls).toBe(2);
    expect(seen.at(-1)!.failed).toBe(false);
    expect(seen.at(-1)!.commands).toEqual([review]);
  } finally {
    act(() => root?.unmount());
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
    dom.window.close();
  }
});
