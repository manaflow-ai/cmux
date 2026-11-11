// l10n-allow-file: test fixtures.
// An opened read or file search draws what it found (FileResultCard.tsx), never its input fields and
// raw output: a read as its file, line range and numbered lines cut to eight; a search as its counts
// and each file's matching lines, each opening the file in cmux. Find reads what the card draws.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { HARNESS_CALLS } from "../toolNamesFixture";
import { setChipHost } from "../chips/host";
import { resetLinkStore } from "../chips/linkStore";
import { activityText } from "./chatFind";
import { TranscriptReadOnly } from "./readOnly";
import { ToolRow } from "./ToolRow";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "NodeFilter",
  "HTMLElement",
  "Element",
  "MutationObserver",
  "customElements",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  setChipHost(undefined);
  resetLinkStore();
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of GLOBALS) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    NodeFilter: dom.window.NodeFilter,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    // The highlighted lines watch the page's theme (HighlightedCode.tsx) when a highlight pool is up.
    MutationObserver: dom.window.MutationObserver,
    // A read's lines load @pierre/diffs, whose web component registers itself once wherever there
    // is an HTMLElement: with no customElements beside it the import fails, for every later file too.
    customElements: dom.window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

async function open(container: HTMLElement) {
  const toggle = container.querySelector<HTMLButtonElement>("button.cv-tool");
  expect(toggle).not.toBeNull();
  await act(async () => toggle!.click());
}

const item = (tool: NonNullable<AcpmuxActivity["tool"]>, output: string): AcpmuxActivity => ({
  kind: "tool",
  text: tool.title,
  tool: { ...tool, output },
});

const READ = Array.from({ length: 12 }, (_, index) => `${String(120 + index).padStart(6)}→line ${index + 1}`).join(
  "\n",
);
const GREP =
  "/work/app/src/a.ts:12:  const x = useTool();\n/work/app/src/a.ts:40:useTool(b)\n/work/app/src/lib/b.ts:3:import { useTool }";

test("an opened Read is its file, line range and numbered lines, cut to eight; closed, one row", async () => {
  const container = await render(<ToolRow item={item(HARNESS_CALLS.claude.read, READ)} />);
  expect(container.querySelector(".cv-filepeek")).toBeNull();
  await open(container);
  expect(container.querySelector(".cv-tool-detail")).toBeNull();
  expect(container.querySelector(".cv-edit-diff__name")?.textContent).toBe("foo.ts");
  expect(container.querySelector(".cv-filepeek__range")?.textContent).toBe("Lines 120–131");
  expect(container.querySelector(".cv-filepeek__gutter")?.textContent?.split("\n")).toEqual(
    Array.from({ length: 12 }, (_, index) => String(120 + index)),
  );
  // The lines without Claude's numbers and arrows.
  expect(container.querySelector(".cv-filepeek__lines")?.textContent).toContain("line 1");
  expect(container.querySelector(".cv-filepeek__lines")?.textContent).not.toContain("→");
  const body = container.querySelector(".cv-filepeek__body")!;
  expect(body.getAttribute("data-preview")).toBe("cut");
  const more = container.querySelector<HTMLButtonElement>(".cv-filepeek .cv-output-more")!;
  expect(more.textContent).toBe("Show all 12 lines");
  await act(async () => more.click());
  expect(body.getAttribute("data-preview")).toBe("all");
});

test("an opened Grep lists matches by file with their line numbers, and a line opens its file", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  // The host places both files in the session's folders.
  setChipHost(async (method, params) => {
    if (method === "link.inspect")
      return {
        paths: Object.fromEntries((params.paths as string[]).map((path) => [path, { place: "root", folder: false }])),
      };
    calls.push([method, params]);
  });
  const container = await render(<ToolRow item={item(HARNESS_CALLS.claude.search, GREP)} />);
  await open(container);
  await act(async () => {});
  expect(container.querySelector(".cv-tool-detail")).toBeNull();
  expect(container.querySelector(".cv-filematches__summary")?.textContent).toBe("3 matches · 2 files");
  expect([...container.querySelectorAll(".cv-filematches__name")].map((node) => node.textContent)).toEqual([
    "a.ts",
    "lib/b.ts",
  ]);
  const lines = [...container.querySelectorAll<HTMLButtonElement>("button.cv-filematches__line")];
  expect(lines.map((node) => node.querySelector(".cv-filematches__number")?.textContent)).toEqual(["12", "40", "3"]);
  expect(lines[0]!.title).toBe("/work/app/src/a.ts:12");
  await act(async () => lines[2]!.click());
  await act(async () => {});
  expect(calls).toEqual([["link.openPath", { path: "/work/app/src/lib/b.ts" }]]);
});

test("a chat on another machine, whose paths the host does not place, draws its files as text", async () => {
  // A remote chat's paths get no place (AgentPaneRemoteChatPathTests): the answer names none.
  setChipHost(async (method) => (method === "link.inspect" ? { paths: {} } : undefined));
  const container = await render(<ToolRow item={item(HARNESS_CALLS.claude.search, GREP)} />);
  await open(container);
  await act(async () => {});
  expect(container.querySelectorAll(".cv-filematches__line").length).toBe(3);
  expect(container.querySelector("button.cv-filematches__line, button.cv-filematches__path")).toBeNull();
});

test("a long search mounts only its preview rows, cuts inside a big file, and says when the harness cut it", async () => {
  const many = Array.from({ length: 500 }, (_, index) => `/w/src/big.ts:${index + 1}:match ${index + 1}`).join("\n");
  const container = await render(
    <ToolRow
      item={item(
        HARNESS_CALLS.claude.search,
        `${many}\n/w/src/small.ts:1:x\n(Results are truncated. Consider a narrower path.)`,
      )}
    />,
  );
  await open(container);
  expect(container.querySelectorAll(".cv-filematches__line").length).toBe(15);
  expect(container.querySelector(".cv-filematches__summary")?.textContent).toBe(
    "501 matches · 2 files · more were left out",
  );
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-filematches .cv-output-more")!.click());
  expect(container.querySelectorAll(".cv-filematches__line").length).toBe(501);
});

test("in a read-only chat a search's files draw as text, never opening the owner's files", async () => {
  const container = await render(
    <TranscriptReadOnly.Provider value>
      <ToolRow item={item(HARNESS_CALLS.claude.search, GREP)} />
    </TranscriptReadOnly.Provider>,
  );
  await open(container);
  expect(container.querySelectorAll(".cv-filematches__line").length).toBe(3);
  expect(container.querySelector("button.cv-filematches__line, button.cv-filematches__path")).toBeNull();
});

test("a result the card cannot read keeps the Input and Output body", async () => {
  const container = await render(
    <ToolRow item={item(HARNESS_CALLS.claude.search, "Directory listing for /work/app:\n[DIR] src")} />,
  );
  await open(container);
  expect(container.querySelector(".cv-filematches")).toBeNull();
  expect(container.querySelector(".cv-tool-detail")).not.toBeNull();
});

test("Find reads a card's lines and paths, never the input fields it no longer draws", () => {
  const read = activityText(item(HARNESS_CALLS.claude.read, READ));
  expect(read).toContain("line 12");
  expect(read).not.toContain("/work/app/src/foo.ts");
  expect(read).not.toContain("→");
  const grep = activityText(item(HARNESS_CALLS.claude.search, GREP));
  expect(grep).toContain("lib/b.ts\nimport { useTool }");
  expect(grep).not.toContain("/work/app/src/a.ts");
});
