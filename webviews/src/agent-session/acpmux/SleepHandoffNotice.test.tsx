// Keep Chats Running When This Mac Sleeps: on wake, the chat says where it ran. This Mac's copy
// of a chat acpmux moved when the Mac slept names the machine and opens the chat there; the chat
// that moved says it is still running there, then that it ran there; a chat that stayed says why.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NoticeSlot } from "./NoticeSlot";
import { SleepHandoffNotice } from "./SleepHandoffNotice";
import { sameSleepHandoffNote, sleepHandoffNote, type SleepHandoffNote } from "./sleepHandoffNote";

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
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(
  note: SleepHandoffNote | undefined,
  canOpen = true,
): Promise<{ container: HTMLElement; opened: string[] }> {
  const container = installDom();
  const opened: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <NoticeSlot>
        <SleepHandoffNotice note={note} canOpen={canOpen} onOpen={(id) => opened.push(id)} />
      </NoticeSlot>,
    );
  });
  return { container, opened };
}

const MOVED = { movedTo: { host: "gcp-1", sessionId: "s-there", why: "sleep", cwd: "/home/u/w" } };

test("the wake readback: this Mac's copy says where the chat went and opens it there", async () => {
  const note = sleepHandoffNote(MOVED, false);
  expect(note).toEqual({ kind: "moved", machine: "gcp-1", routed: "gcp-1/s-there" });
  const { container, opened } = await render(note);
  expect(container.querySelector("[data-sleep-handoff]")!.getAttribute("data-sleep-handoff")).toBe("moved");
  expect(container.querySelector(".acpmux-host-line-message")!.textContent).toBe(
    "Moved to gcp-1 when this Mac went to sleep",
  );
  await act(async () => container.querySelector("button")!.click());
  expect(opened).toEqual(["gcp-1/s-there"]);
});

test("a moved chat the list does not have yet offers no Open", async () => {
  const { container } = await render(sleepHandoffNote(MOVED, false), false);
  expect(container.querySelector("button")).toBeNull();
});

test("the chat that moved says it still runs there, then that it ran there", async () => {
  const summary = { peer: "gcp-1", tags: { sleepHandoff: "moved", sleepHandoffFrom: "leos-mbp" } };
  let { container } = await render(sleepHandoffNote(summary, true));
  expect(container.textContent).toBe("Still running on gcp-1 while leos-mbp sleeps");
  await act(async () => root!.unmount());
  root = undefined;
  ({ container } = await render(sleepHandoffNote(summary, false)));
  expect(container.textContent).toBe("Ran on gcp-1 while leos-mbp slept");
  const here = sleepHandoffNote({ tags: summary.tags }, true);
  expect(here).toEqual({ kind: "running", machine: undefined, from: "leos-mbp" });
});

test("a chat that stayed says why", async () => {
  const why = "its uncommitted .env (.env file: it may hold secrets, so it is shared only on purpose) can't go with it";
  const { container } = await render(
    sleepHandoffNote({ tags: { sleepHandoff: "stayed", sleepHandoffWhy: why } }, true),
  );
  expect(container.textContent).toBe(`Stayed on this Mac when it went to sleep: ${why}`);
});

test("only a sleep move notes anything", () => {
  expect(sleepHandoffNote(undefined, true)).toBeUndefined();
  expect(sleepHandoffNote({ movedTo: { host: "gcp-1", sessionId: "s" } }, false)).toBeUndefined();
  expect(sleepHandoffNote({ movedTo: null, tags: { area: "x" } }, false)).toBeUndefined();
  expect(sleepHandoffNote({ tags: { sleepHandoff: "moved" } }, false)).toBeUndefined();
  expect(sleepHandoffNote({ movedTo: { host: "gcp-1", sessionId: "gcp-1/s", why: "sleep" } }, false)).toEqual({
    kind: "moved",
    machine: "gcp-1",
    routed: "gcp-1/s",
  });
});

test("a snapshot that says the same keeps the note", () => {
  const a = sleepHandoffNote(MOVED, false);
  expect(sameSleepHandoffNote(a, sleepHandoffNote(MOVED, true))).toBe(true);
  expect(sameSleepHandoffNote(a, sleepHandoffNote({ movedTo: { ...MOVED.movedTo, host: "gcp-2" } }, false))).toBe(
    false,
  );
  expect(sameSleepHandoffNote(undefined, undefined)).toBe(true);
});
