import { describe, expect, test } from "bun:test";
import "../../Resources/markdown-viewer/viewer-navigation.js";
import { bootPageDiff } from "../src/diff/pageBoot";
import { DIFF_PAGE_COMMAND_ACTIONS, runDiffPageCommand } from "../src/diff/pageCommands";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";

// The commands the app's key dispatcher sends a diff page (CmuxNextPages DiffPageCommand.all plus
// the shared find and focusSearch), diff-host.md S4.
const HOST_COMMANDS = [
  "nextLine",
  "previousLine",
  "halfPageDown",
  "halfPageUp",
  "nextHunk",
  "previousHunk",
  "goToTop",
  "goToBottom",
  "nextFile",
  "previousFile",
  "toggleViewed",
  "collapseFile",
  "expandFile",
  "find",
  "focusSearch",
];

/** A page bridge that serves the config and keeps the page streams' handlers. */
function fakePage() {
  const streams = new Map<string, (data: unknown, seq: number) => void>();
  const page: PageClient = {
    async call<R>(op: string) {
      if (op === "cmux.diff.config") return { payload: { title: "Diff" } } as R;
      throw pageError("cmux.protocol.unknown_op", op);
    },
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      if (stream !== "cmux.page.command") throw pageError("cmux.protocol.unknown_op", stream);
      streams.set(stream, onEvent as (data: unknown, seq: number) => void);
      return () => void streams.delete(stream);
    },
    handle: () => () => undefined,
  };
  let seq = 0;
  return { page, push: (data: unknown) => streams.get("cmux.page.command")?.(data, ++seq), streams };
}

describe("diff page host commands", () => {
  test("every command the host sends has a navigation action", () => {
    expect(Object.keys(DIFF_PAGE_COMMAND_ACTIONS).sort()).toEqual([...HOST_COMMANDS].sort());
  });

  test("a command runs its action; an unknown command runs nothing", () => {
    const ran: string[] = [];
    const perform = (action: string) => (ran.push(action), true);
    expect(runDiffPageCommand({ command: "nextHunk" }, perform)).toBe(true);
    expect(runDiffPageCommand({ command: "find", text: "x" } as never, perform)).toBe(true);
    expect(runDiffPageCommand({ command: "zoomIn" }, perform)).toBe(false);
    expect(runDiffPageCommand({}, perform)).toBe(false);
    expect(ran).toEqual(["diffViewerNextHunk", "diffViewerOpenFind"]);
  });

  test("the line, half page and edge commands are the shared scroll motions", () => {
    const scrolled: number[] = [];
    const scroller = {
      scrollTop: 100,
      scrollHeight: 2000,
      clientHeight: 400,
      scrollTo: ({ top }: { top: number }) => scrolled.push(top),
    };
    for (const command of ["nextLine", "previousLine", "halfPageDown", "halfPageUp", "goToTop", "goToBottom"]) {
      const action = DIFF_PAGE_COMMAND_ACTIONS[command]!;
      expect(CmuxViewerNavigation.performAction(action, scroller as never)).toBe(true);
    }
    expect(scrolled).toHaveLength(6);
  });

  test("the booted page runs the commands the host pushes on cmux.page.command", async () => {
    const { page, push, streams } = fakePage();
    const ran: string[] = [];
    await bootPageDiff(
      page,
      () => undefined,
      () => undefined,
      undefined,
      undefined,
      (action) => (ran.push(action), true),
    );
    expect(streams.has("cmux.page.command")).toBe(true);
    push({ command: "nextFile" });
    push({ command: "collapseFile" });
    expect(ran).toEqual(["diffViewerNextFile", "diffViewerCollapseFile"]);
  });
});
