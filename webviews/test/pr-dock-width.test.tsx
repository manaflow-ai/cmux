// l10n-allow-file: test fixture commands and titles, not shipped UI.
// A pull request bar uses the composer column's width and cuts its title off only when the column
// is full; then, and only then, the bar's full name and title are a hover away (Leo 2026-10-20).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "localStorage", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://example.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

const tool = (id: string, command: string, output = "") => ({
  id,
  tool: { id, kind: "execute", title: command, status: "completed", exitCode: 0, command, output },
});

const title = "rulebook: reviewed PRs merge right away; the label is the fallback";

/// Renders one bar and reports its tooltip after a hover, with the title drawn `drawn` px wide in
/// a box of `box` px.
async function hoverTitle(drawn: number, box: number): Promise<string | null> {
  const { createRoot } = await import("react-dom/client");
  const { PullRequestDock } = await import("../src/agent-session/acpmux/summary/PullRequestDock");
  const rows = [
    {
      kind: "activity",
      id: "a1",
      version: 1,
      items: [tool("t1", `gh pr create --title "${title}"`, "https://github.com/manaflow-ai/leo-workspace/pull/634")],
    },
  ];
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => root.render(<PullRequestDock rows={rows as never} sessionId={`s${drawn}`} />));
  const bar = host.querySelector<HTMLElement>(".acpmux-pr-dock__bar")!;
  const text = bar.querySelector<HTMLElement>(".acpmux-pr-dock__title")!;
  Object.defineProperty(text, "scrollWidth", { configurable: true, value: drawn });
  Object.defineProperty(text, "clientWidth", { configurable: true, value: box });
  await act(async () => {
    bar.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
  });
  const result = bar.getAttribute("title");
  act(() => root.unmount());
  return result;
}

test("a cut-off title is a hover away", async () => {
  expect(await hoverTitle(620, 300)).toBe(`manaflow-ai/leo-workspace#634 ${title}`);
});

test("a title that fits has no tooltip", async () => {
  expect(await hoverTitle(300, 300)).toBeNull();
});
