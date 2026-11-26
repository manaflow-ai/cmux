// The agent dot signature on the running line (conversation/agentSignatureModel.ts, AgentSignature.tsx).
// Leo, 2026-11-19: "all of them" and "some of them maybe just as customizations lol if it affects
// default looks": appearance.agentSignature is off by default, and off the line is today's line with
// no request to acpmux; on, it draws the chat's glyph from `session/signature` before its words.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import {
  AgentSignatureContext,
  type AgentSignatureSource,
  configureAgentSignature,
  readGlyph,
  resetAgentSignatures,
} from "../src/agent-session/acpmux/conversation/agentSignatureModel";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { settleReact } from "./support/domTeardown";

const SESSION = "sess-dot-signature";
const GLYPH = {
  seed: 0.37,
  variant: "Dust",
  accent: "#3D7BFF",
  drift: 1,
  dots: [
    { x: 0.31, y: 0.52, r: 0.11, phase: 0.4 },
    { x: 0.62, y: 0.35, r: 0.08, phase: 0.1 },
    { x: 0.55, y: 0.7, r: 0.13, phase: 0.9 },
    { x: 0.4, y: 0.25, r: 0.07, phase: 0.6 },
    { x: 0.72, y: 0.6, r: 0.09, phase: 0.2 },
  ],
};

function source(): AgentSignatureSource & { asked: string[][] } {
  const asked: string[][] = [];
  return {
    asked,
    sessionId: SESSION,
    fetch: async (ids) => {
      asked.push(ids);
      return { signatures: { [SESSION]: GLYPH } };
    },
  };
}

afterEach(() => resetAgentSignatures());

async function mount(src: AgentSignatureSource) {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  const scope = globalThis as Record<string, unknown>;
  const saved = { window: scope.window, document: scope.document, IS: scope.IS_REACT_ACT_ENVIRONMENT };
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => {
    root.render(
      <AgentSignatureContext.Provider value={src}>
        <Thinking since={Date.now() - 42_000} />
      </AgentSignatureContext.Provider>,
    );
  });
  // The ask resolves on a microtask; let its redraw land.
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
  const html = host.innerHTML;
  const circles = host.querySelectorAll(".cv-signature .cv-signature__at");
  const circleList = [...circles].map((circle) => ({
    color: (circle.parentElement as HTMLElement | null)?.style.color ?? "",
    left: (circle as HTMLElement).style.left,
  }));
  await act(async () => root.unmount());
  await settleReact();
  scope.window = saved.window;
  scope.document = saved.document;
  scope.IS_REACT_ACT_ENVIRONMENT = saved.IS;
  dom.window.close();
  return { html, circles: circleList };
}

test("off: the line is today's, and acpmux is asked nothing", async () => {
  const src = source();
  const bare = renderToStaticMarkup(<Thinking />);
  const withSource = renderToStaticMarkup(
    <AgentSignatureContext.Provider value={src}>
      <Thinking />
    </AgentSignatureContext.Provider>,
  );
  expect(withSource).toBe(bare);
  const { html, circles } = await mount(src);
  expect(circles).toHaveLength(0);
  expect(html).not.toContain("cv-signature");
  expect(src.asked).toEqual([]);
});

test("on: the line draws one dot per glyph dot in the accent, asked once for the pane's chat", async () => {
  configureAgentSignature(true);
  const src = source();
  const { html, circles } = await mount(src);
  expect(circles).toHaveLength(GLYPH.dots.length);
  for (const circle of circles) {
    expect(circle.color).not.toBe("");
    expect(circle.left).toMatch(/%$/);
  }
  // The glyph comes before the words.
  expect(html.indexOf("cv-signature")).toBeLessThan(html.indexOf("cv-thinking"));
  expect(src.asked).toEqual([[SESSION]]);
  // A second line for the same chat reads the page's cache: no second ask.
  const again = await mount(src);
  expect(again.circles).toHaveLength(GLYPH.dots.length);
  expect(src.asked).toEqual([[SESSION]]);
});

test("a malformed glyph draws nothing", () => {
  expect(readGlyph({ accent: "blue", dots: GLYPH.dots })).toBeUndefined();
  expect(readGlyph({ accent: "#3D7BFF", dots: [] })).toBeUndefined();
  expect(readGlyph(GLYPH)?.dots).toHaveLength(5);
});
