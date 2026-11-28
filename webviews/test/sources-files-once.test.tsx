// The chat's Sources popover listed a file the last turn edited twice (cx-0h4xq, dogfood run 6):
// under Outputs, the chat's files, and again under Changes, the last turn's. Codex lists it once:
// a file the last turn changed shows under Changes, and Outputs keeps the chat's other files.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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

async function sourcesRows(outputs: never[], changed: never[]) {
  const { createRoot } = await import("react-dom/client");
  const { SummaryBody } = await import("../src/agent-session/acpmux/summary/SummaryBody");
  act(() => root?.unmount());
  root = createRoot(host);
  const summary = { scheduled: [], pullRequests: [], outputs, subagents: [], sources: [], backgroundTasks: [] };
  const changes = { additions: 1, deletions: 0, files: changed };
  await act(async () => root!.render(<SummaryBody summary={summary} changes={changes} onOpenChanges={() => {}} />));
  const sections: Record<string, string[]> = Object.fromEntries(
    [...host.querySelectorAll("section")].map((section) => [
      section.getAttribute("aria-label") ?? section.querySelector("h3")?.textContent,
      [...section.querySelectorAll("li")].map((row) => row.textContent ?? ""),
    ]),
  );
  return sections;
}

function expectOnceUnderChanges(sections: Record<string, string[]>) {
  const rows = Object.values(sections).flat();
  expect(rows.filter((row) => row.includes("upload.sh")).length).toBe(1);
  expect((sections["Changes"] ?? []).some((row) => row.includes("upload.sh"))).toBe(true);
  expect((sections["Outputs"] ?? []).some((row) => row.includes("README.md"))).toBe(true);
}

test("a file the last turn changed shows once, under Changes", async () => {
  expectOnceUnderChanges(
    await sourcesRows([file("/repo/src/upload.sh", 1), file("/repo/README.md", 4)], [file("/repo/src/upload.sh", 1)]),
  );
});

// Once the turn's checkpoint loads, Changes lists its files under the repository root, while the
// chat's outputs keep the paths the agent wrote (`~/code/x/src/upload.sh`).
test("a file the turn's checkpoint lists shows once, under Changes", async () => {
  const checkpoint = {
    ...(file("/Users/me/code/x/src/upload.sh", 1) as object),
    displayPath: "src/upload.sh",
  } as never;
  expectOnceUnderChanges(
    await sourcesRows([file("~/code/x/src/upload.sh", 1), file("~/code/x/README.md", 4)], [checkpoint]),
  );
});
