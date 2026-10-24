// l10n-allow-file: test fixture file names and patch text, not shipped UI.
// Open the file from the diff (D4): the file name and the header menu open the file through the
// host's `cmux.diff.openFile`, and a Cmd-click on a diff line opens it at that line of the file as
// it is now. An old-side line maps through Pierre's own parsed hunks; a deleted file offers no open.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { parsePatchFiles } from "@pierre/diffs";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { loadDiffViewerLabels, createDiffViewerLabelResolver } = await import("../src/labels");
await loadDiffViewerLabels("en");
const { FileHeader } = await import("../src/diff-viewer/FileHeader");
const { diffFileOpenCall, isCmdLineNumberPress, linesMatchDisk, newSideLine, openFromLineClick, opensFile } =
  await import("../src/diff-viewer/openFile");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/** One file's parsed diff, as the viewer gets it from Pierre. */
function parsed(patch: string) {
  const file = parsePatchFiles(patch)[0]?.files[0];
  if (!file) throw new Error("patch did not parse");
  return file;
}

/** Every old-side line of the patch with the new-side line it must open, read from the text alone. */
function expectedOldLines(patch: string): [old: number, expected: number][] {
  const out: [number, number][] = [];
  let oldLine = 0;
  let newLine = 0;
  let pending: number[] = [];
  let added = 0;
  const flush = () => {
    // Removed lines take the added lines of their block in order, then the line after the block.
    pending.forEach((old, index) =>
      out.push([old, added > 0 ? newLine - added + Math.min(index, added - 1) : newLine]),
    );
    pending = [];
    added = 0;
  };
  for (const line of patch.split("\n")) {
    const header = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line);
    if (header) {
      flush();
      oldLine = Number(header[2] ?? 1) === 0 ? Number(header[1]) + 1 : Number(header[1]);
      newLine = Number(header[4] ?? 1) === 0 ? Number(header[3]) + 1 : Number(header[3]);
      continue;
    }
    if (line.startsWith("-") && !line.startsWith("---")) {
      if (added > 0) flush();
      pending.push(oldLine++);
    } else if (line.startsWith("+") && !line.startsWith("+++")) {
      added++;
      newLine++;
    } else if (line.startsWith(" ")) {
      flush();
      out.push([oldLine++, newLine++]);
    }
  }
  flush();
  return out;
}

const MIXED = [
  "diff --git a/src/upload.ts b/src/upload.ts",
  "--- a/src/upload.ts",
  "+++ b/src/upload.ts",
  "@@ -3,8 +3,9 @@ export function upload() {",
  " const a = 1;",
  "-const retries = 3;",
  "-const delay = 10;",
  "+const retries = 9;",
  " const b = 2;",
  " const c = 3;",
  "-const gone = true;",
  " const d = 4;",
  "+const added = 1;",
  "+const more = 2;",
  "+const third = 3;",
  " const e = 5;",
  "@@ -20,3 +21,5 @@ function tail() {",
  " const x = 1;",
  "+const y = 2;",
  "+const z = 3;",
  " const w = 4;",
  " const v = 5;",
  "",
].join("\n");

describe("a clicked diff line opens the file at its line as it is now", () => {
  test("a new-side line is itself", () => {
    expect(newSideLine(parsed(MIXED).hunks, "additions", 12)).toBe(12);
    expect(newSideLine([], "additions", 0)).toBe(1);
  });

  test("every old-side line of a mixed patch maps as the patch text says", () => {
    const { hunks } = parsed(MIXED);
    expect(expectedOldLines(MIXED)).toHaveLength(11);
    for (const [old, expected] of expectedOldLines(MIXED))
      expect([old, newSideLine(hunks, "deletions", old)]).toEqual([old, expected]);
    // Spelled out: two removed lines with one added in their place both open it (line 4), a removed
    // line with nothing added opens the line now after it (line 7, "const d").
    expect(newSideLine(hunks, "deletions", 4)).toBe(4);
    expect(newSideLine(hunks, "deletions", 5)).toBe(4);
    expect(newSideLine(hunks, "deletions", 8)).toBe(7);
  });

  test("lines outside the hunks shift by the hunks above them", () => {
    const { hunks } = parsed(MIXED);
    expect(newSideLine(hunks, "deletions", 1)).toBe(1);
    // The first hunk turns 8 old lines into 9: old 15 (between the hunks) is new 16.
    expect(newSideLine(hunks, "deletions", 15)).toBe(16);
    // The second adds 2 more lines: old 30 is new 33.
    expect(newSideLine(hunks, "deletions", 30)).toBe(33);
  });

  test("a removal at the end of the file opens the line before it", () => {
    const patch = ["--- a/f.ts", "+++ b/f.ts", "@@ -8,3 +8,1 @@", " last kept", "-gone 1", "-gone 2", ""].join("\n");
    expect(newSideLine(parsed(patch).hunks, "deletions", 9)).toBe(8);
    expect(newSideLine(parsed(patch).hunks, "deletions", 10)).toBe(8);
  });

  test("a hunk that leaves no new lines opens the line before the removal", () => {
    const patch = ["--- a/f.ts", "+++ b/f.ts", "@@ -5,2 +4,0 @@", "-gone 1", "-gone 2", ""].join("\n");
    expect(newSideLine(parsed(patch).hunks, "deletions", 5)).toBe(4);
    expect(newSideLine(parsed(patch).hunks, "deletions", 6)).toBe(4);
    // And after it, lines shift up by two.
    expect(newSideLine(parsed(patch).hunks, "deletions", 10)).toBe(8);
  });

  test("a pure insertion (an empty old side) shifts the lines after it", () => {
    const patch = ["--- a/f.ts", "+++ b/f.ts", "@@ -5,0 +6,2 @@", "+new 1", "+new 2", ""].join("\n");
    expect(newSideLine(parsed(patch).hunks, "deletions", 5)).toBe(5);
    expect(newSideLine(parsed(patch).hunks, "deletions", 6)).toBe(8);
  });
});

describe("Cmd-click on a line", () => {
  const click = (event: Partial<MouseEvent>, lineNumber: number, annotationSide?: "additions" | "deletions") => {
    let prevented = false;
    return {
      click: {
        event: {
          metaKey: false,
          ctrlKey: false,
          altKey: false,
          shiftKey: false,
          button: 0,
          ...event,
          preventDefault: () => (prevented = true),
        },
        lineNumber,
        annotationSide,
      },
      prevented: () => prevented,
    };
  };

  test("opens the file at the new-side line; a plain click opens nothing", () => {
    const fileDiff = { ...parsed(MIXED), name: "src/upload.ts" };
    const opened: unknown[] = [];
    const open = (path: string, line?: number) => void opened.push([path, line]);
    const plain = click({}, 5, "deletions");
    expect(openFromLineClick(plain.click, fileDiff, open)).toBeNull();
    expect(plain.prevented()).toBe(false);
    const withShift = click({ metaKey: true, shiftKey: true }, 5, "deletions");
    expect(openFromLineClick(withShift.click, fileDiff, open)).toBeNull();
    const cmd = click({ metaKey: true }, 5, "deletions");
    expect(openFromLineClick(cmd.click, fileDiff, open)).toBe("line");
    expect(cmd.prevented()).toBe(true);
    expect(openFromLineClick(click({ metaKey: true }, 12, "additions").click, fileDiff, open)).toBe("line");
    expect(opened).toEqual([
      ["src/upload.ts", 4],
      ["src/upload.ts", 12],
    ]);
  });

  test("a diff that is not of the files on disk opens the file at the top", () => {
    const fileDiff = { ...parsed(MIXED), name: "src/upload.ts" };
    const opened: unknown[] = [];
    const open = (path: string, line?: number) => void opened.push([path, line]);
    expect(openFromLineClick(click({ metaKey: true }, 12, "additions").click, fileDiff, open, false)).toBe("top");
    expect(opened).toEqual([["src/upload.ts", undefined]]);
    // The work tree against a base, Unstaged, and Last turn's patch name lines on disk; Staged does not.
    expect(linesMatchDisk({ kind: "unstaged" })).toBe(true);
    expect(linesMatchDisk({ kind: "branch" })).toBe(true);
    expect(linesMatchDisk({ kind: "patch" })).toBe(true);
    expect(linesMatchDisk({ kind: "staged" })).toBe(false);
    expect(linesMatchDisk(null)).toBe(false);
  });

  test("Cmd on a line number is kept from the line selection", () => {
    const number = dom.window.document.createElement("span");
    number.setAttribute("data-column-number", "12");
    const code = dom.window.document.createElement("span");
    code.setAttribute("data-line", "12");
    const press = (metaKey: boolean, path: EventTarget[], button = 0) => ({
      metaKey,
      button,
      composedPath: () => path,
    });
    expect(isCmdLineNumberPress(press(true, [number, code]))).toBe(true);
    expect(isCmdLineNumberPress(press(false, [number]))).toBe(false);
    expect(isCmdLineNumberPress(press(true, [code]))).toBe(false);
    expect(isCmdLineNumberPress(press(true, [number], 2))).toBe(false);
  });

  test("a deleted file, or a host without the op, opens nothing", () => {
    const opened: unknown[] = [];
    const open = (path: string, line?: number) => void opened.push([path, line]);
    expect(
      openFromLineClick(
        click({ metaKey: true }, 2, "deletions").click,
        { name: "old.ts", type: "deleted", hunks: [] },
        open,
      ),
    ).toBeNull();
    expect(
      openFromLineClick(click({ metaKey: true }, 2).click, { name: "a.ts", type: "change", hunks: [] }, undefined),
    ).toBeNull();
    expect(opened).toEqual([]);
    expect(opensFile({ name: "a.ts", type: "new" })).toBe(true);
    expect(opensFile({ name: "a.ts", type: "deleted" })).toBe(false);
    expect(opensFile({ type: "change" })).toBe(false);
  });
});

test("the open is the host's op, only where the host lists it", async () => {
  const calls: [string, unknown][] = [];
  const page = { call: async (op: string, params: unknown) => void calls.push([op, params]) } as never;
  expect(diffFileOpenCall(page, ["cmux.diff.git.status"])).toBeUndefined();
  expect(diffFileOpenCall(null, ["cmux.diff.openFile"])).toBeUndefined();
  const call = diffFileOpenCall(page, ["cmux.diff.openFile"])!;
  await call("src/upload.ts", 12);
  await call("src/upload.ts", undefined, "finder");
  expect(calls).toEqual([
    ["cmux.diff.openFile", { path: "src/upload.ts", where: "tab", line: 12 }],
    ["cmux.diff.openFile", { path: "src/upload.ts", where: "finder" }],
  ]);
});

describe("the file header", () => {
  const label = createDiffViewerLabelResolver(undefined, { language: "en" });
  async function render(fileDiff: Record<string, unknown>) {
    const opened: unknown[] = [];
    let toggles = 0;
    await act(async () =>
      root.render(
        <FileHeader
          item={{ id: "f1", fileDiff: { hunks: [], ...fileDiff } } as never}
          label={label}
          onLoadDiff={() => {}}
          onOpenFile={(path, line, where) => void opened.push([path, line, where])}
          onToggleCollapsed={() => toggles++}
          onToggleViewed={() => {}}
          viewedState="unviewed"
        />,
      ),
    );
    return { opened, toggles: () => toggles };
  }
  const nameButton = () => host.querySelector<HTMLButtonElement>("button.file-header-open");
  const menuRows = async () => {
    if (!dom.window.document.querySelector(".file-header-menu"))
      await act(async () => host.querySelector<HTMLButtonElement>(".file-header-menu-button")!.click());
    return [...dom.window.document.querySelectorAll<HTMLButtonElement>(".file-header-menu [role=menuitem]")];
  };

  test("the name opens the file and does not fold it; the bar still folds", async () => {
    const { opened, toggles } = await render({ name: "src/upload.ts", type: "change" });
    expect(nameButton()?.textContent).toBe("upload.ts");
    await act(async () => nameButton()!.click());
    expect(opened).toEqual([["src/upload.ts", undefined, undefined]]);
    expect(toggles()).toBe(0);
    await act(async () => host.querySelector<HTMLElement>(".file-header-spacer")!.click());
    expect(toggles()).toBe(1);
  });

  test("a drag over the name selects it and opens nothing", async () => {
    const { opened } = await render({ name: "src/upload.ts", type: "change" });
    const button = nameButton()!;
    await act(async () => {
      button.dispatchEvent(
        new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0, clientX: 10, clientY: 10 }),
      );
      button.dispatchEvent(
        new dom.window.MouseEvent("click", { bubbles: true, button: 0, detail: 1, clientX: 60, clientY: 10 }),
      );
    });
    expect(opened).toEqual([]);
  });

  test("a double click opens once; a key's click opens after a drag that ended elsewhere", async () => {
    const { opened } = await render({ name: "src/upload.ts", type: "change" });
    const button = nameButton()!;
    const fire = (type: string, init: MouseEventInit) =>
      button.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, button: 0, ...init }));
    await act(async () => {
      fire("mousedown", { clientX: 10, clientY: 10 });
      fire("click", { detail: 1, clientX: 10, clientY: 10 });
      fire("mousedown", { clientX: 10, clientY: 10 });
      fire("click", { detail: 2, clientX: 10, clientY: 10 });
    });
    expect(opened).toHaveLength(1);
    // A press on the name whose drag ended outside it leaves no click; Enter's click still opens.
    await act(async () => {
      fire("mousedown", { clientX: 10, clientY: 10 });
      fire("click", { detail: 0, clientX: 0, clientY: 0 });
    });
    expect(opened).toHaveLength(2);
  });

  test("the menu opens the file in a tab, the editor app or Finder", async () => {
    const { opened } = await render({ name: "src/upload.ts", type: "change" });
    const labels = (await menuRows()).map((row) => row.textContent);
    expect(labels.slice(0, 3)).toEqual(["Open file", "Open in editor", "Reveal in Finder"]);
    for (const index of [0, 1, 2]) {
      const rows = await menuRows();
      await act(async () => rows[index]!.click());
    }
    expect(opened).toEqual([
      ["src/upload.ts", undefined, undefined],
      ["src/upload.ts", undefined, "editor"],
      ["src/upload.ts", undefined, "finder"],
    ]);
  });

  test("a deleted file has no open: plain name, no open rows", async () => {
    await render({ name: "src/gone.ts", type: "deleted" });
    expect(nameButton()).toBeNull();
    expect(host.querySelector(".file-header-name")?.textContent).toBe("gone.ts");
    const labels = (await menuRows()).map((row) => row.textContent);
    expect(labels).not.toContain("Open file");
    expect(labels).not.toContain("Reveal in Finder");
  });
});
