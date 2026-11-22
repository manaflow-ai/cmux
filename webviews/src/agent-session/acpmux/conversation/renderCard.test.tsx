import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { RENDER_FRAME_URL, RenderCard, ranRenders } from "./RenderCard";
import { renderCall } from "./renderCall";
import { RENDER, turnView } from "./turns";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const tool = (title: string, input: unknown, extra: Partial<Tool> = {}): Tool => ({
  id: title,
  title,
  kind: "other",
  status: "completed",
  inputSummary: JSON.stringify(input),
  ...extra,
});
const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind,
  ...extra,
});
const call = (id: string, input: unknown) =>
  row(id, "activity", 2, { items: [{ kind: "tool", text: "", tool: { ...tool("mcp__cmux__render", input), id } }] });

describe("render calls", () => {
  test("reads the HTML and title of a render tool under any harness's MCP name", () => {
    const input = { html: "<h1>Plan</h1>", title: "Pricing mock" };
    for (const title of ["mcp__cmux__render", "cmux.render", "cmux/render", "render", "html_render", "render (cmux)"])
      expect(renderCall(tool(title, input))).toEqual({ html: "<h1>Plan</h1>", title: "Pricing mock" });
    expect(renderCall(tool("render", { html: "<p>x</p>" }))).toEqual({ html: "<p>x</p>", title: undefined });
  });

  test("leaves other tools, empty HTML and failed or unfinished calls alone", () => {
    expect(renderCall(tool("mcp__cmux__prerender", { html: "<p>x</p>" }))).toBeUndefined();
    expect(renderCall(tool("Render the page", { html: "<p>x</p>" }))).toBeUndefined();
    expect(renderCall(tool("render", { html: "  " }))).toBeUndefined();
    expect(renderCall(tool("render", { markup: "<p>x</p>" }))).toBeUndefined();
    expect(renderCall(tool("render", { html: "<p>x</p>" }, { status: "failed" }))).toBeUndefined();
    // A turn cancelled mid-call ends with the call still pending: it never ran, so it draws nothing.
    expect(renderCall(tool("render", { html: "<p>x</p>" }, { status: "pending" }))).toBeUndefined();
    expect(renderCall(tool("render", { html: "<p>x</p>" }, { status: "in_progress" }))).toBeUndefined();
  });

  test("an ended turn shows each render above its answer, in call order; a running one waits", () => {
    const rows = [
      row("u", "user", 0, { text: "mock two pricing pages" }),
      call("r1", { html: "<p>A</p>" }),
      call("r2", { html: "<p>B</p>" }),
      row("a", "assistant", 3, { text: "Here are two." }),
      row("s", "turnSummary", 4, { durationMs: 4, toolCount: 2, status: "completed" }),
    ];
    const view = turnView(rows, new Set(), { now: 10 });
    const at = view.findIndex((entry) => entry.kind === RENDER);
    expect(view.slice(at, at + 3).map((entry) => entry.id)).toEqual(["render-r1", "render-r2", "a"]);
    expect(view[at]!.items![0]!.tool!.id).toBe("r1");
    expect(
      turnView(rows.slice(0, 4), new Set(), { now: 10, working: true }).some((entry) => entry.kind === RENDER),
    ).toBe(false);
  });

  test("agent HTML waits for Run: no frame loads until the reader runs it", () => {
    // A busy loop in agent HTML would freeze the pane, which shares the frame's process, so nothing
    // runs on its own; a card the reader ran stays running while the pane lives.
    const waiting = renderToStaticMarkup(createElement(RenderCard, { call: { html: "<p>wait</p>", title: "Mock" } }));
    expect(waiting).not.toContain("<iframe");
    expect(waiting).toContain(">Run</button>");
    expect(waiting).toContain(">Mock</span>");
    ranRenders.add("<p>wait</p>");
    const running = renderToStaticMarkup(createElement(RenderCard, { call: { html: "<p>wait</p>", title: "Mock" } }));
    expect(running).toContain(`src="${RENDER_FRAME_URL}"`);
    expect(running).not.toContain(">Run</button>");
  });

  test("the card frames the render origin sandboxed without same-origin", () => {
    ranRenders.add("<p>x</p>");
    const html = renderToStaticMarkup(createElement(RenderCard, { call: { html: "<p>x</p>", title: "Mock" } }));
    expect(html).toContain(`src="${RENDER_FRAME_URL}"`);
    expect(html).toContain('sandbox="allow-scripts"');
    expect(html).not.toContain("allow-same-origin");
    expect(html).toContain(">Mock</span>");
    // The HTML goes to the frame by message, never into the pane's own markup.
    expect(html).not.toContain("<p>x</p>");
    expect(renderToStaticMarkup(createElement(RenderCard, { call: { html: "<p>x</p>" } }))).toContain(
      ">Preview</span>",
    );
  });

  test("the card's classes leave the row's own class alone", () => {
    // A row is `acpmux-row acpmux-<kind>`, absolutely placed by the virtual transcript; a card
    // styled under that class would take the row out of its place and hide the rows below it.
    const html = renderToStaticMarkup(createElement(RenderCard, { call: { html: "<p>x</p>" } }));
    for (const [, name] of html.matchAll(/class="([^"]+)"/g))
      expect(name!.split(" ")).not.toContain(`acpmux-${RENDER}`);
  });
});
