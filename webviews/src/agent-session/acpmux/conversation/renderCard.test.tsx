import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { RenderCard, canRender, setRenderFrame } from "./RenderCard";
import { RenderGroup } from "./RenderGroup";
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

  test("reads which option the agent recommends", () => {
    expect(renderCall(tool("render", { html: "<p>x</p>", recommended: true }))?.recommended).toBe(true);
    expect(renderCall(tool("render", { html: "<p>x</p>", recommended: "yes" }))).toEqual({ html: "<p>x</p>", title: undefined });
  });

  test("options sit side by side with the recommended one marked and each one expandable", () => {
    const html = renderToStaticMarkup(
      createElement(RenderGroup, {
        calls: [
          { html: "<p>a</p>", title: "Nested 4 px", recommended: true },
          { html: "<p>b</p>", title: "Nested 8 px" },
        ],
      }),
    );
    expect(html).toContain("grid-template-columns:repeat(2, minmax(0, 1fr))");
    expect(html.match(/<iframe/g)).toHaveLength(2);
    expect(html.match(/>Recommended</g)).toHaveLength(1);
    expect(html.indexOf(">Recommended<")).toBeLessThan(html.indexOf("Nested 8 px"));
    expect(html.match(/>Expand</g)).toHaveLength(2);
  });

  test("leaves other tools, empty HTML and failed calls alone", () => {
    expect(renderCall(tool("mcp__cmux__prerender", { html: "<p>x</p>" }))).toBeUndefined();
    expect(renderCall(tool("Render the page", { html: "<p>x</p>" }))).toBeUndefined();
    expect(renderCall(tool("render", { html: "  " }))).toBeUndefined();
    expect(renderCall(tool("render", { markup: "<p>x</p>" }))).toBeUndefined();
    expect(renderCall(tool("render", { html: "<p>x</p>" }, { status: "failed" }))).toBeUndefined();
  });

  test("an ended turn shows its renders as one row above its answer, in call order; a running one waits", () => {
    const rows = [
      row("u", "user", 0, { text: "mock two pricing pages" }),
      call("r1", { html: "<p>A</p>" }),
      call("r2", { html: "<p>B</p>" }),
      row("a", "assistant", 3, { text: "Here are two." }),
      row("s", "turnSummary", 4, { durationMs: 4, toolCount: 2, status: "completed" }),
    ];
    const view = turnView(rows, new Set(), { now: 10 });
    const at = view.findIndex((entry) => entry.kind === RENDER);
    expect(view.slice(at, at + 2).map((entry) => entry.id)).toEqual(["render-r1", "a"]);
    expect(view[at]!.items!.map((item) => item.tool!.id)).toEqual(["r1", "r2"]);
    expect(
      turnView(rows.slice(0, 4), new Set(), { now: 10, working: true }).some((entry) => entry.kind === RENDER),
    ).toBe(false);
  });

  test("off the bundled pane, only a host's http(s) frame renders", () => {
    // The test page is not cmux-agent:, so it has no render origin of its own.
    expect(canRender()).toBe(false);
    for (const url of [
      undefined,
      7,
      "",
      "javascript:alert(1)",
      "data:text/html,<p>x</p>",
      "file:///tmp/frame.html",
      "frame",
    ])
      setRenderFrame(url);
    expect(canRender()).toBe(false);
    setRenderFrame("http://127.0.0.1:4176/render-frame.html");
    expect(canRender()).toBe(true);
  });

  test("the card frames the render frame sandboxed without same-origin", () => {
    setRenderFrame("http://127.0.0.1:4176/render-frame.html");
    const html = renderToStaticMarkup(createElement(RenderCard, { call: { html: "<p>x</p>", title: "Mock" } }));
    expect(html).toContain('src="http://127.0.0.1:4176/render-frame.html"');
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
