// Settings > Sidebar > Workspace Rows > Row Layout (CMUX-383): the model (rowLayout.ts) keeps every
// write inside the sidebar_row_layout reducer's bounds, and the editor (editors/RowLayoutEditor.tsx)
// edits the three layout keys, maps a daemon refusal's problems onto its items, and resets.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { installDom } from "./testDom";
import {
  BY_AGENT_KEY,
  BY_KIND_KEY,
  LINES_KEY,
  addToken,
  layoutFromSwitches,
  moveToken,
  problemPlace,
  problemToken,
  readLayout,
  readMap,
  refusalProblems,
  removeLine,
  removeToken,
  stepPlace,
  toggleSlot,
  writeLayout,
  writeMap,
  type Layout,
} from "./rowLayout";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, rowElement, click, fire, changeValue, ops } = await import("./testing");

const layout = (value: unknown): Layout => readLayout(value)!;

describe("the model", () => {
  test("a stored layout reads as it applies: known tokens once, name first, slots apart", () => {
    const read = layout([["branch", "icon", "name", "bogus", 3, "branch"], [], ["name", "ports", "working"], "x"]);
    expect([...read.slots].sort()).toEqual(["icon", "working"]);
    expect(read.lines).toEqual([["branch"], ["ports"]]);
    expect(writeLayout(read)).toEqual([["icon", "name", "branch", "working"], ["ports"]]);
    expect(readLayout("lines")).toBeNull();
    expect(readLayout({})).toBeNull();
    expect(layout([]).lines).toEqual([[]]);
    expect(writeLayout(layout([]))).toEqual([["name"]]);
  });

  test("at most three lines of six text tokens, as the reducer draws", () => {
    const read = layout([
      ["name", "directory", "branch", "process", "agentStatus", "tabCount", "ports", "log"],
      ["lastActivity"],
      ["pullRequest"],
      ["notification"],
    ]);
    expect(read.lines).toEqual([
      ["directory", "branch", "process", "agentStatus", "tabCount", "ports"],
      ["lastActivity"],
      ["pullRequest"],
    ]);
    // A full line takes nothing more; a fourth line never starts.
    expect(addToken(read, 0, "log")).toBe(read);
    expect(addToken(read, 3, "log")).toBe(read);
    expect(addToken(read, 1, "log").lines[1]).toEqual(["lastActivity", "log"]);
  });

  test("edits: add, remove, move, remove a line, slots", () => {
    const start = layout([["icon", "name", "branch"], ["directory"]]);
    expect(addToken(start, 2, "ports").lines).toEqual([["branch"], ["directory"], ["ports"]]);
    expect(addToken(start, 0, "branch")).toBe(start);
    // Removing a later line's last token drops the line.
    expect(removeToken(start, { line: 1, index: 0 }).lines).toEqual([["branch"]]);
    expect(removeLine(start, 1).lines).toEqual([["branch"]]);
    // Line one only empties: it holds the name.
    expect(removeLine(start, 0).lines).toEqual([[], ["directory"]]);
    expect(moveToken(start, { line: 0, index: 0 }, { line: 1, index: 0 }).lines).toEqual([[], ["branch", "directory"]]);
    expect(moveToken(start, { line: 1, index: 0 }, { line: 0, index: 0 }).lines).toEqual([["directory", "branch"]]);
    expect(moveToken(start, { line: 0, index: 0 }, { line: 2, index: 0 }).lines).toEqual([
      [],
      ["directory"],
      ["branch"],
    ]);
    expect(writeLayout(toggleSlot(toggleSlot(start, "icon"), "progress"))).toEqual([
      ["name", "branch", "progress"],
      ["directory"],
    ]);
  });

  test("keyboard steps stay inside the bounds", () => {
    const start = layout([["name", "branch", "ports"], ["directory"]]);
    expect(stepPlace(start, { line: 0, index: 0 }, "left")).toBeNull();
    expect(stepPlace(start, { line: 0, index: 0 }, "right")).toEqual({ line: 0, index: 1 });
    expect(stepPlace(start, { line: 0, index: 1 }, "down")).toEqual({ line: 1, index: 1 });
    expect(stepPlace(start, { line: 1, index: 0 }, "up")).toEqual({ line: 0, index: 2 });
    // The last line's only chip has no new line to go to.
    expect(stepPlace(start, { line: 1, index: 0 }, "down")).toBeNull();
    expect(stepPlace(start, { line: 0, index: 0 }, "up")).toBeNull();
  });

  test("customizing starts from the row the switches draw", () => {
    const values: Record<string, unknown> = {
      "sidebar.workspaceRow.icon": true,
      "sidebar.workspaceRow.working": true,
      "sidebar.workspaceRow.progress": false,
      "sidebar.workspaceRow.branch": true,
      "sidebar.workspaceRow.ports": true,
      "sidebar.workspaceRow.log": true,
      "sidebar.workspaceRow.secondLineOrder": ["ports", "branch"],
    };
    const start = layoutFromSwitches((key) => values[key]);
    expect(writeLayout(start)).toEqual([
      ["icon", "name", "working"],
      ["ports", "branch", "log"],
    ]);
    expect(writeLayout(layoutFromSwitches(() => undefined))).toEqual([["name"]]);
  });

  test("by-kind and by-agent maps keep their order and drop an entry set to null", () => {
    const entries = readMap({ agent: [["name"]], terminal: "nope", browser: [["name", "ports"]] });
    expect(entries.map(([key]) => key)).toEqual(["agent", "browser"]);
    expect(writeMap(entries, "agent", null)).toEqual({ browser: [["name", "ports"]] });
    expect(Object.keys(writeMap(entries, "mixed", layout([["name"]])))).toEqual(["agent", "browser", "mixed"]);
  });

  test("a refusal's problems map to their key, entry, line and token", () => {
    expect(problemPlace("sidebar.workspaceRow.lines[1][0]")).toEqual({
      key: LINES_KEY,
      entry: null,
      line: 1,
      index: 0,
    });
    expect(problemPlace("sidebar.workspaceRow.linesByKind.agent[0][2]")).toEqual({
      key: BY_KIND_KEY,
      entry: "agent",
      line: 0,
      index: 2,
    });
    expect(problemPlace("sidebar.workspaceRow.linesByAgent")).toEqual({
      key: BY_AGENT_KEY,
      entry: null,
      line: null,
      index: null,
    });
    expect(problemPlace("browser.newTabPage")).toBeNull();
    const problems = refusalProblems({
      accepted: { problems: [{ at: "sidebar.workspaceRow.lines[0][1]", why: "repeated" }, { why: "x" }] },
    });
    expect(problems).toEqual([{ at: "sidebar.workspaceRow.lines[0][1]", why: "repeated" }]);
    // The item index counts the written list, slots included.
    expect(problemToken(problems[0]!, [["icon", "branch", "branch"]])).toBe("branch");
    expect(refusalProblems({ problems: [{ at: "a", why: "b", token: "t" }] })).toEqual([
      { at: "a", why: "b", token: "t" },
    ]);
    expect(refusalProblems(undefined)).toEqual([]);
  });
});

describe("the editor", () => {
  let page: Awaited<ReturnType<typeof renderPage>> | null = null;
  afterEach(() => {
    page?.unmount();
    page = null;
  });
  const open = async (options: Parameters<typeof renderPage>[0] = {}) => {
    page = await renderPage({ path: `/settings/sidebar?focus=${LINES_KEY}`, ...options });
    return page;
  };
  const editor = () => rowElement(page!.container, LINES_KEY).querySelector<HTMLElement>("[data-row-layout-editor]")!;
  const chips = (line: number) =>
    [...editor().querySelectorAll<HTMLElement>(`[data-layout-line="${line}"] [data-chip]`)].map(
      (chip) => chip.dataset.chip,
    );
  const sets = (key: string) =>
    (ops(page!.provider, "cmux.settings.set") as { key: string; value: unknown }[]).filter((op) => op.key === key);
  const tab = async (name: string) => {
    const trigger = [...editor().querySelectorAll<HTMLElement>('[role="tab"]')].find(
      (item) => item.textContent === name,
    )!;
    await click(trigger);
  };

  test("the row draws the editor, the name pinned first on line one", async () => {
    await open({ mock: { values: { [LINES_KEY]: [["icon", "name", "branch"], ["agentStatus"]] } } });
    expect(rowElement(page!.container, LINES_KEY).dataset.kind).toBe("json");
    const first = editor().querySelector('[data-layout-line="0"] .row-layout-chip')!;
    expect(first.hasAttribute("data-pinned")).toBe(true);
    expect(first.querySelector(".row-layout-chip-name")!.textContent).toBe("Name");
    expect(chips(0)).toEqual(["branch"]);
    expect(chips(1)).toEqual(["agentStatus"]);
    const icon = editor().querySelector<HTMLButtonElement>('[data-slot="icon"]')!;
    expect(icon.getAttribute("aria-pressed")).toBe("true");
    expect(editor().querySelector('[data-slot="working"]')!.getAttribute("aria-pressed")).toBe("false");
    // The two companion keys draw inside this row, not as rows of their own.
    expect(page!.container.querySelector(`[data-row-key="${BY_KIND_KEY}"]`)).toBeNull();
  });

  test("the preview draws the row the layout makes and follows each edit", async () => {
    await open({ mock: { values: { [LINES_KEY]: [["icon", "name", "branch", "working"], ["agentStatus"]] } } });
    const preview = () => editor().querySelector<HTMLElement>("[data-row-layout-preview]")!;
    const lines = () =>
      [...preview().querySelectorAll<HTMLElement>("[data-preview-line]")].map((line) =>
        [...line.querySelectorAll<HTMLElement>("[data-token]")].map((item) => item.dataset.token),
      );
    expect(preview().querySelector(".row-layout-preview-name")!.textContent).toBe("cmux");
    expect(lines()).toEqual([["branch"], ["agentStatus"]]);
    expect(preview().querySelector('[data-preview-slot="icon"]')).not.toBeNull();
    expect(preview().querySelector('[data-preview-slot="working"]')).not.toBeNull();
    expect(preview().querySelector('[data-preview-slot="progress"]')).toBeNull();
    await click(editor().querySelector('[data-slot="progress"]')!);
    expect(preview().querySelector('[data-preview-slot="progress"]')).not.toBeNull();
    await click(editor().querySelector('[data-chip="agentStatus"] .row-layout-chip-remove')!);
    expect(lines()).toEqual([["branch"]]);
  });

  test("remove, slot toggle, keyboard move and Delete each write one whole layout", async () => {
    await open({ mock: { values: { [LINES_KEY]: [["icon", "name", "branch", "ports"], ["agentStatus"]] } } });
    await click(editor().querySelector('[data-chip="ports"] .row-layout-chip-remove')!);
    expect(sets(LINES_KEY).at(-1)!.value).toEqual([["icon", "name", "branch"], ["agentStatus"]]);
    await click(editor().querySelector('[data-slot="working"]')!);
    expect(sets(LINES_KEY).at(-1)!.value).toEqual([["icon", "name", "branch", "working"], ["agentStatus"]]);
    // Option-Down takes Git Branch to the end of line two.
    await fire(editor().querySelector('[data-chip="branch"] .row-layout-chip-grab')!, "keydown", {
      key: "ArrowDown",
      altKey: true,
    });
    expect(sets(LINES_KEY).at(-1)!.value).toEqual([
      ["icon", "name", "working"],
      ["agentStatus", "branch"],
    ]);
    expect(chips(1)).toEqual(["agentStatus", "branch"]);
    await fire(editor().querySelector('[data-chip="agentStatus"] .row-layout-chip-grab')!, "keydown", {
      key: "Delete",
    });
    expect(sets(LINES_KEY).at(-1)!.value).toEqual([["icon", "name", "working"], ["branch"]]);
  });

  test("Add Line starts a line with the item picked; the + adds to its line", async () => {
    await open({ mock: { values: { [LINES_KEY]: [["name", "branch"]] } } });
    const addLine = editor().querySelector<HTMLButtonElement>(".row-layout-add-line")!;
    await click(addLine);
    const item = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
      (row) => row.getAttribute("data-value") === "directory",
    )!;
    // Items already on the layout are not offered.
    expect(document.querySelector('[role="menuitem"][data-value="branch"]')).toBeNull();
    await click(item);
    expect(sets(LINES_KEY).at(-1)!.value).toEqual([["name", "branch"], ["directory"]]);
    await click(editor().querySelector('[data-layout-line="1"] .row-layout-add')!);
    await click(document.querySelector('[role="menuitem"][data-value="ports"]')!);
    expect(sets(LINES_KEY).at(-1)!.value).toEqual([
      ["name", "branch"],
      ["directory", "ports"],
    ]);
  });

  test("with no layout, Customize starts from the switches; Use Item Switches resets the key", async () => {
    await open({ mock: { values: { "sidebar.workspaceRow.branch": true } } });
    expect(editor().querySelector(".row-layout-empty")).not.toBeNull();
    await click(editor().querySelector('[data-row-layout-action="customize"]')!);
    const written = sets(LINES_KEY).at(-1)!.value as string[][];
    expect(written[1]).toEqual(["branch"]);
    expect(written[0]).toContain("name");
    expect(chips(1)).toEqual(["branch"]);
    await click(editor().querySelector('[data-row-layout-action="reset"]')!);
    expect(ops(page!.provider, "cmux.settings.reset").at(-1)).toMatchObject({ key: LINES_KEY });
    expect(editor().querySelector(".row-layout-empty")).not.toBeNull();
  });

  test("a refused write keeps the last good layout and names the problem beside its item", async () => {
    await open({
      mock: {
        values: { [LINES_KEY]: [["name", "branch"], ["ports"]] },
        refusals: {
          [LINES_KEY]: {
            message: "sidebar.workspaceRow.lines[1][0]: repeated",
            details: { accepted: { problems: [{ at: "sidebar.workspaceRow.lines[0][1]", why: "repeated" }] } },
          },
        },
      },
    });
    await click(editor().querySelector('[data-chip="ports"] .row-layout-chip-remove')!);
    // The store rolled back: Ports is still shown and stored.
    expect(chips(1)).toEqual(["ports"]);
    expect(page!.store.getSnapshot().rows.get(LINES_KEY)?.value).toEqual([["name", "branch"], ["ports"]]);
    const problem = editor().querySelector('.row-layout-problems [data-why="repeated"]')!;
    expect(problem.textContent).toBe("Git Branch shows only once");
    expect(editor().querySelector('[data-chip="branch"]')!.hasAttribute("data-problem")).toBe(true);
  });

  test("By Kind: Customize a kind, then Remove it resets the key", async () => {
    await open({ mock: { values: { [LINES_KEY]: [["icon", "name"], ["directory"]] } } });
    await tab("By Kind");
    const agent = () => editor().querySelector<HTMLElement>('[data-row-layout-entry="agent"]')!;
    expect(agent().textContent).toContain("Uses All Rows");
    await click(agent().querySelector('[data-row-layout-action="customize-entry"]')!);
    expect(sets(BY_KIND_KEY).at(-1)!.value).toEqual({ agent: [["icon", "name"], ["directory"]] });
    await click(agent().querySelector('[data-row-layout-action="remove-entry"]')!);
    expect(ops(page!.provider, "cmux.settings.reset").at(-1)).toMatchObject({ key: BY_KIND_KEY });
  });

  test("By Agent: an agent id added gets a layout; a taken id is refused in place", async () => {
    await open({ mock: { values: { [BY_AGENT_KEY]: { codex: [["name", "branch"]] } } } });
    await tab("By Agent");
    const field = editor().querySelector<HTMLInputElement>(".row-layout-agent-field")!;
    await changeValue(field, "codex");
    expect(editor().querySelector<HTMLButtonElement>('[data-row-layout-action="add-agent"]')!.disabled).toBe(true);
    expect(editor().textContent).toContain("codex already has a layout");
    await changeValue(field, " Claude ");
    await click(editor().querySelector('[data-row-layout-action="add-agent"]')!);
    // With no All Rows layout it starts from today's row: the default switches' icon, working and progress.
    expect(sets(BY_AGENT_KEY).at(-1)!.value).toEqual({
      codex: [["name", "branch"]],
      claude: [["icon", "name", "working", "progress"]],
    });
  });

  test("a link to By Kind opens the editor on its tab", async () => {
    page = await renderPage({ path: `/settings/sidebar?focus=${BY_KIND_KEY}` });
    await settle();
    const row = rowElement(page.container, BY_KIND_KEY);
    const active = row.querySelector('[role="tab"][aria-selected="true"]')!;
    expect(active.textContent).toBe("By Kind");
  });
});
