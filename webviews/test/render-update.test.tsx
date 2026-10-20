// A render that names an earlier render's id updates that page in place (cx-ncc.94): the card the
// first call drew shows the new page, the update draws no card of its own, the new page waits for
// Run as any page does, and the side panel lists the earlier page as a previous version. The id is
// the one `cmux mcp`'s render returns (cmux-tui tests/mcp_render_update.rs pins the same value).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: dom.window.location,
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
  IntersectionObserver: class {
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
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const FIRST = "<title>Desk clamp</title><p>Jaw 3°</p>";
/// The id `cmux mcp`'s render returns for FIRST.
const FIRST_ID = "r680bc59027";
const SECOND = "<title>Desk clamp</title><p>Jaw 5°</p>";

/// One ended render tool call, as the transcript holds it.
const call = (id: string, input: Record<string, unknown>, status = "completed", output?: string): AcpmuxRow => ({
  id: `row-${id}`,
  version: 1,
  at: 0,
  kind: "activity",
  items: [
    {
      kind: "tool",
      text: "mcp__cmux__render",
      tool: { id, title: "mcp__cmux__render", status, inputSummary: JSON.stringify(input), output },
    },
  ],
});
const original = call("toolu_1", { html: FIRST, title: "Desk clamp" });
const update = call("toolu_2", { id: FIRST_ID, html: SECOND, title: "Desk clamp, thicker jaw" });

const button = (label: string) =>
  [...host.querySelectorAll("button")].find(
    (element) => element.getAttribute("aria-label") === label || element.textContent === label,
  );

/// The transcript's render rows for `rows`, as the pane draws them.
async function draw(rows: AcpmuxRow[], open?: (artifact: unknown) => void) {
  const { createRoot } = await import("react-dom/client");
  const { RenderToolCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  const { RenderPages, renderPages } = await import("../src/agent-session/acpmux/conversation/renderCall");
  const { ArtifactContext } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
  root ??= createRoot(host);
  act(() =>
    root!.render(
      <ArtifactContext.Provider value={open}>
        <RenderPages.Provider value={renderPages(rows)}>
          {rows.flatMap((row) => {
            const tool = row.items?.[0]?.tool;
            return tool ? [<RenderToolCard key={row.id} tool={tool} />] : [];
          })}
        </RenderPages.Provider>
      </ArtifactContext.Provider>,
    ),
  );
}

const cards = () => [...host.querySelectorAll(".acpmux-render-card")];
const title = () => cards()[0]?.querySelector(".acpmux-render-card-title")?.textContent;

test("a render naming an earlier render's id updates that card in place, and the new page waits for Run", async () => {
  await draw([original]);
  expect(cards()).toHaveLength(1);
  expect(title()).toBe("Desk clamp");
  act(() => button("Run")!.click());
  expect(host.querySelector("iframe")).not.toBeNull();

  // The update arrives in a later turn: still one card, now the new page.
  await draw([original, update]);
  expect(cards()).toHaveLength(1);
  expect(title()).toBe("Desk clamp, thicker jaw");
  // Running the first page does not run the second: it waits for Run, as every page does.
  expect(host.querySelector("iframe")).toBeNull();
  act(() => button("Run")!.click());
  expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("allow-scripts");
});

test("a render without an id is its own card, as before", async () => {
  await draw([original, call("toolu_3", { html: SECOND, title: "Another clamp" })]);
  expect(cards().map((card) => card.querySelector(".acpmux-render-card-title")?.textContent)).toEqual([
    "Desk clamp",
    "Another clamp",
  ]);
});

test("the same page rendered twice without an id is two cards, and an update joins the latest", async () => {
  const again = call("toolu_4", { html: FIRST, title: "Desk clamp again" });
  await draw([original, again]);
  expect(cards().map((card) => card.querySelector(".acpmux-render-card-title")?.textContent)).toEqual([
    "Desk clamp",
    "Desk clamp again",
  ]);
  // An update naming the page's id goes to the most recent card that shows it.
  await draw([original, again, update]);
  expect(cards().map((card) => card.querySelector(".acpmux-render-card-title")?.textContent)).toEqual([
    "Desk clamp",
    "Desk clamp, thicker jaw",
  ]);
});

test("the updated card opens its page in the side panel with the earlier page as a previous version", async () => {
  const opened: { kind: "html"; lang: string; code: string; render?: string }[] = [];
  await draw([original, update], (artifact) => opened.push(artifact as (typeof opened)[number]));
  act(() => button("Open preview")!.click());
  // The card goes by the call that drew it.
  expect(opened).toEqual([{ kind: "html", lang: "html", code: SECOND, render: "toolu_1" }]);

  const { renderPages, renderVersions } = await import("../src/agent-session/acpmux/conversation/renderCall");
  const versions = renderVersions(renderPages([original, update]), opened[0]!);
  expect(versions?.map((version) => version.code)).toEqual([FIRST, SECOND]);

  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  act(() => root!.render(<ArtifactPanel artifact={opened[0]!} versions={versions} onClose={() => {}} />));
  const count = () => host.querySelector(".acpmux-artifact-version")?.textContent;
  expect(count()).toBe("2/2");
  act(() => button("Previous version")!.click());
  expect(count()).toBe("1/2");
});

const titles = () => cards().map((card) => card.querySelector(".acpmux-render-card-title")?.textContent);
const THIRD = "<title>Desk clamp</title><p>Jaw 7°</p>";

test("a chain of updates each naming the first page shows the last, with every page a version", async () => {
  const third = call("toolu_5", { id: FIRST_ID, html: THIRD, title: "Desk clamp, final" });
  const opened: { kind: "html"; lang: string; code: string; render?: string }[] = [];
  await draw([original, update, third], (artifact) => opened.push(artifact as (typeof opened)[number]));
  expect(titles()).toEqual(["Desk clamp, final"]);
  act(() => button("Open preview")!.click());
  const { renderPages, renderVersions } = await import("../src/agent-session/acpmux/conversation/renderCall");
  const versions = renderVersions(renderPages([original, update, third]), opened[0]!);
  expect(versions?.map((version) => version.code)).toEqual([FIRST, SECOND, THIRD]);
});

test("an update that only renames the page shows the new title", async () => {
  await draw([original, call("toolu_6", { id: FIRST_ID, html: FIRST, title: "Desk clamp, renamed" })]);
  expect(titles()).toEqual(["Desk clamp, renamed"]);
});

test("a refused update draws nothing and leaves the card as it was", async () => {
  // A harness that reports the refusal as failed, and one that reports it as completed.
  const refusal = JSON.stringify({ error: { code: "invalid", message: "render has no page" }, state: "not_run" });
  await draw([
    original,
    call("toolu_7", { id: FIRST_ID, html: SECOND, title: "Failed" }, "failed", refusal),
    call("toolu_8", { id: FIRST_ID, html: THIRD, title: "Refused" }, "completed", refusal),
  ]);
  expect(titles()).toEqual(["Desk clamp"]);
});

test("a streaming delta reads no render input again and keeps the cards' pages", async () => {
  const { renderPages } = await import("../src/agent-session/acpmux/conversation/renderCall");
  const rows = [original, update];
  const pages = renderPages(rows);
  await draw(rows);
  const parse = JSON.parse;
  let parsed = 0;
  JSON.parse = ((text: string, reviver?: Parameters<typeof parse>[1]) => {
    if (typeof text === "string" && text.includes("<title>")) parsed += 1;
    return parse(text, reviver);
  }) as typeof JSON.parse;
  try {
    const delta: AcpmuxRow = {
      id: "answer",
      version: 1,
      at: 0,
      kind: "assistant",
      text: "Here is the",
      streaming: true,
    };
    const next = [...rows, delta];
    expect(renderPages(next)).toBe(pages);
    await draw(next);
    expect(renderPages([...rows, { ...delta, version: 2, text: "Here is the clamp" }])).toBe(pages);
  } finally {
    JSON.parse = parse;
  }
  expect(parsed).toBe(0);
});
