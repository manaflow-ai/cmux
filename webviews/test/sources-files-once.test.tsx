// The chat's Sources popover listed a file the last turn edited twice (cx-0h4xq, dogfood run 6):
// under Outputs, the chat's files, and again under Changes, the last turn's. It lists it once, under
// Outputs with every file the chat changed (hq#2569 item 4: a chat that edited files said "Outputs:
// None"); Changes is the one row that opens the last turn's diff with its totals.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import { activity, tool } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const file = (path: string, additions: number) =>
  ({ path, displayPath: path.split("/").pop()!, edits: [], additions, deletions: 0, created: false }) as never;

async function sourcesRows(
  outputs: never[],
  changed: never[],
  onOpenChanges: (path?: string) => void = () => {},
  onOpenOutput: (path: string) => void = () => {},
  cwd?: string,
) {
  const { createRoot } = await import("react-dom/client");
  const { SummaryBody } = await import("../src/agent-session/acpmux/summary/SummaryBody");
  act(() => root?.unmount());
  root = createRoot(host);
  const summary = {
    ...(cwd ? { cwd } : {}),
    scheduled: [],
    pullRequests: [],
    outputs,
    subagents: [],
    sources: [],
    backgroundTasks: [],
  };
  const changes = { additions: 1, deletions: 0, files: changed };
  await act(async () =>
    root!.render(
      <SummaryBody summary={summary} changes={changes} onOpenChanges={onOpenChanges} onOpenOutput={onOpenOutput} />,
    ),
  );
  const sections: Record<string, string[]> = Object.fromEntries(
    [...host.querySelectorAll("section")].map((section) => [
      section.getAttribute("aria-label") ?? section.querySelector("h3")?.textContent,
      [...section.querySelectorAll("li")].map((row) => row.textContent ?? ""),
    ]),
  );
  return sections;
}

function expectOnceUnderOutputs(sections: Record<string, string[]>) {
  const rows = Object.values(sections).flat();
  expect(rows.filter((row) => row.includes("upload.sh")).length).toBe(1);
  expect((sections["Outputs"] ?? []).some((row) => row.includes("upload.sh"))).toBe(true);
  expect((sections["Outputs"] ?? []).some((row) => row.includes("README.md"))).toBe(true);
  expect(sections["Changes"]).toEqual(["Changes+1-0"]);
}

test("a file the last turn changed shows once, under Outputs", async () => {
  expectOnceUnderOutputs(
    await sourcesRows([file("/repo/src/upload.sh", 1), file("/repo/README.md", 4)], [file("/repo/src/upload.sh", 1)]),
  );
});

// Once the turn's checkpoint loads, its files are under the repository root, while the chat's
// outputs keep the paths the agent wrote (`~/code/x/src/upload.sh`): still listed once.
test("a file the turn's checkpoint lists shows once, under Outputs", async () => {
  const checkpoint = {
    ...(file("/Users/me/code/x/src/upload.sh", 1) as object),
    displayPath: "src/upload.sh",
  } as never;
  expectOnceUnderOutputs(
    await sourcesRows([file("~/code/x/src/upload.sh", 1), file("~/code/x/README.md", 4)], [checkpoint]),
  );
});

// A turn can edit one file with an edit tool and another with a shell command or formatter: only
// the checkpoint knows the second. It is listed under Outputs too, and opens the turn's diff there.
test("a file only the turn's checkpoint knows shows under Outputs and opens the turn's diff at it", async () => {
  const opened: (string | undefined)[] = [];
  const formatted = { ...(file("/repo/src/format.ts", 2) as object), displayPath: "src/format.ts" } as never;
  const sections = await sourcesRows(
    [file("/repo/src/upload.sh", 1)],
    [file("/repo/src/upload.sh", 1), formatted],
    (path) => opened.push(path),
  );
  expect(sections["Outputs"]?.filter((row) => row.includes("format.ts")).length).toBe(1);
  expect(sections["Outputs"]?.filter((row) => row.includes("upload.sh")).length).toBe(1);
  const row = [...host.querySelectorAll<HTMLButtonElement>("section button")].find((button) =>
    button.textContent?.includes("format.ts"),
  )!;
  await act(async () => row.click());
  expect(opened).toEqual(["/repo/src/format.ts"]);
});

// An earlier turn edited a file with a tool, and the last turn changed it again (by a shell command,
// say): its row opens the last turn's diff, where its latest change is, not the earlier turn's.
test("a file the last turn changed again opens the last turn's diff", async () => {
  const opened: string[] = [];
  const outputsOpened: string[] = [];
  const again = { ...(file("/repo/src/upload.sh", 3) as object), displayPath: "src/upload.sh" } as never;
  const sections = await sourcesRows(
    [file("/repo/src/upload.sh", 1), file("/repo/README.md", 4)],
    [again],
    (path) => opened.push(path!),
    (path) => outputsOpened.push(path),
  );
  expect(sections["Outputs"]?.filter((row) => row.includes("upload.sh"))).toEqual(["src/upload.sh+3-0"]);
  const button = (name: string) =>
    [...host.querySelectorAll<HTMLButtonElement>("section button")].find((b) => b.textContent?.includes(name))!;
  await act(async () => button("upload.sh").click());
  await act(async () => button("README.md").click());
  expect(opened).toEqual(["/repo/src/upload.sh"]);
  expect(outputsOpened).toEqual(["/repo/README.md"]);
});

// Review on #22166: a file named like one the last turn changed, in another folder, is its own output.
test("a same-named file in another folder keeps its own row and opens its own changes", async () => {
  const opened: string[] = [];
  const outputsOpened: string[] = [];
  // Before the checkpoint loads, a one-file turn's file reads by its bare name.
  const last = { ...(file("/repo/b/index.ts", 2) as object), displayPath: "index.ts" } as never;
  await sourcesRows(
    [file("/repo/a/index.ts", 1), file("/repo/b/index.ts", 2)],
    [last],
    (path) => opened.push(path!),
    (path) => outputsOpened.push(path),
  );
  const buttons = [...host.querySelectorAll<HTMLButtonElement>("section button")].filter((b) =>
    b.textContent?.includes("index.ts"),
  );
  expect(buttons.length).toBe(2);
  for (const button of buttons) await act(async () => button.click());
  expect(opened).toEqual(["/repo/b/index.ts"]);
  expect(outputsOpened).toEqual(["/repo/a/index.ts"]);
});

test("an out-of-project checkpoint cannot replace an allowed output with the same display path", async () => {
  const opened: string[] = [];
  const allowed = { ...(file("/repo/src/index.ts", 1) as object), displayPath: "src/index.ts" } as never;
  const outside = {
    ...(file("/elsewhere/src/index.ts", 9) as object),
    displayPath: "src/index.ts",
    canonical: "/elsewhere/src/index.ts",
  } as never;
  const sections = await sourcesRows(
    [allowed],
    [outside],
    () => {},
    (path) => opened.push(path),
    "/repo",
  );
  expect(sections["Outputs"]?.filter((row) => row.includes("index.ts"))).toEqual(["src/index.ts+1-0"]);
  const button = [...host.querySelectorAll<HTMLButtonElement>("section button")].find((b) =>
    b.textContent?.includes("index.ts"),
  );
  await act(async () => button?.click());
  expect(opened).toEqual(["/repo/src/index.ts"]);
});

// A checkpoint's root file takes the root output, not a package's file of the same name.
test("a checkpoint's root package.json is the root output, not a package's", async () => {
  const opened: string[] = [];
  const outputsOpened: string[] = [];
  const root = { ...(file("/Users/me/repo/package.json", 1) as object), displayPath: "package.json" } as never;
  await sourcesRows(
    [file("~/repo/packages/x/package.json", 3), file("~/repo/package.json", 1)],
    [root],
    (path) => opened.push(path!),
    (path) => outputsOpened.push(path),
  );
  const buttons = [...host.querySelectorAll<HTMLButtonElement>("section button")].filter((b) =>
    b.textContent?.includes("package.json"),
  );
  expect(buttons.length).toBe(2);
  for (const button of buttons) await act(async () => button.click());
  expect(opened).toEqual(["/Users/me/repo/package.json"]);
  expect(outputsOpened).toEqual(["~/repo/packages/x/package.json"]);
});

test("completed searches without URLs remain named Sources", () => {
  const sources = sessionSummary([
    activity([tool("Search retry policies", "fetch", "completed", { inputSummary: '{"query":"retry policies"}' })], 1),
  ]).sources;
  expect(sources).toEqual([{ label: "Search retry policies" }]);
});
