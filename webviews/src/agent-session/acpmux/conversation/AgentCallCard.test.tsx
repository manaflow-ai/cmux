// l10n-allow-file: test fixtures.
// A Claude subagent call's card (AgentCallCard.tsx): one compact line with its kind, words, state
// and time; opened, its report as Markdown and its prompt behind "Show prompt".
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { AgentCallCard } from "./AgentCallCard";
import { agentCall } from "./agentCalls";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const tool = (fields: Partial<Tool> = {}): Tool => ({
  id: "toolu_card",
  title: "Agent: Find the parser",
  kind: "think",
  status: "completed",
  inputSummary: JSON.stringify({
    description: "Find the parser",
    prompt: "Find where the parser **drops** results.",
    subagent_type: "Explore",
  }),
  output: "It drops them in **parse.ts**.\nagentId: a1b2\n<usage>tool_uses: 14\nduration_ms: 72000</usage>",
  ...fields,
});

test("a finished call is one line: kind, words, Done, time and tool uses; opened, the report as Markdown", async () => {
  const item = tool();
  const container = await render(<AgentCallCard call={agentCall(item)!} tool={item} />);
  const line = container.querySelector<HTMLButtonElement>(".cv-disclosure__toggle")!;
  expect(container.querySelector(".cv-agentcall__type")?.textContent).toBe("Explore");
  expect(container.querySelector(".cv-disclosure__label")?.textContent).toBe("Explore Find the parser");
  expect(container.querySelector(".cv-agentcall__status")?.textContent).toBe("Done · 1m 12s · 14 tool uses");
  expect(line.getAttribute("aria-expanded")).toBe("false");
  expect(container.querySelector(".cv-disclosure__panel")).toBeNull();
  await act(async () => line.click());
  const panel = container.querySelector(".cv-disclosure__panel")!;
  expect(panel.querySelector("strong")?.textContent).toBe("parse.ts");
  // The trailer is Claude Code's, never the report's.
  expect(panel.textContent).not.toContain("agentId");
  // The prompt waits behind its toggle.
  expect(panel.textContent).not.toContain("drops results");
  const show = [...panel.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === "Show prompt")!;
  await act(async () => show.click());
  expect(panel.textContent).toContain("Find where the parser drops results.");
});

test("a running call says Working and shows its prompt when opened", async () => {
  const running = tool({ status: "in_progress", output: undefined });
  const container = await render(<AgentCallCard call={agentCall(running)!} tool={running} />);
  expect(container.querySelector(".cv-agentcall__status")?.getAttribute("data-state")).toBe("working");
  expect(container.querySelector(".cv-agentcall__status")?.textContent).toContain("Working");
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-disclosure__toggle")!.click());
  expect(container.querySelector(".cv-disclosure__panel")?.textContent).toContain("Find where the parser drops");
});

test("a failed call says Failed", async () => {
  const failed = tool({ status: "failed", output: "Agent stopped." });
  const container = await render(<AgentCallCard call={agentCall(failed)!} tool={failed} />);
  const status = container.querySelector(".cv-agentcall__status")!;
  expect(status.getAttribute("data-state")).toBe("failed");
  expect(status.textContent).toBe("Failed");
});
