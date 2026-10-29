// The transcript's sub-session rows are one-line disclosures: the prompt opens as Markdown below
// the anchored line, while adjacent starts collapse into one group row.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { SubsessionCallCard } from "../src/agent-session/acpmux/conversation/SubsessionCallCard";
import type { SubsessionCall } from "../src/agent-session/acpmux/conversation/subsessionCalls";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

const start = (name: string, sessionId = `${name}-id`): Extract<SubsessionCall, { tool: "start" }> => ({
  tool: "start",
  running: false,
  sessionId,
  name,
  prompt: `# ${name}\n\nRun the **full** review and report the result.`,
  harness: "claude",
  model: "opus",
});

const tool = (name: string) =>
  ({
    id: `${name}-call`,
    title: "mcp__cmux-subsessions__start_session",
    status: "completed",
    inputSummary: JSON.stringify({ name, prompt: `Own the ${name} lane` }),
    output: `Started sub-session ${name} (sessionId ${name}-id, depth 1).`,
  }) as never;

function installDom() {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("a collapsed sub-session is one disclosure row and expansion renders the full Markdown prompt", async () => {
  const container = installDom();
  const scroll = container.ownerDocument.createElement("div");
  scroll.style.overflowY = "auto";
  const mount = container.ownerDocument.createElement("div");
  scroll.append(mount);
  container.append(scroll);
  root = createRoot(mount);
  await act(async () => root!.render(<SubsessionCallCard call={start("msg-fold")} tool={tool("msg-fold")} />));
  const row = container.querySelector<HTMLElement>(".cv-disclosure")!;
  expect(row.querySelectorAll(".cv-disclosure__line")).toHaveLength(1);
  expect(row.textContent).not.toContain("Run the full review");
  scroll.scrollTop = 37;
  const before = scroll.scrollTop;
  await act(async () => row.querySelector<HTMLButtonElement>(".cv-disclosure__toggle")!.click());
  expect(scroll.scrollTop).toBe(before);
  expect(row.textContent).toContain("full review");
  expect(row.querySelector(".cv-disclosure__label")?.textContent).toContain("msg-fold");
});

test("three adjacent starts render as one collapsed group row", () => {
  const html = renderToStaticMarkup(
    <SubsessionCallCard
      group={[
        { call: start("msg-fold"), tool: tool("msg-fold") },
        { call: start("picker-polish"), tool: tool("picker-polish") },
        { call: start("cloud-demo"), tool: tool("cloud-demo") },
      ]}
    />,
  );
  expect((html.match(/class="cv-disclosure"/g) ?? []).length).toBe(1);
  expect(html).toContain("3 sessions: msg-fold, picker-polish, cloud-demo");
});
