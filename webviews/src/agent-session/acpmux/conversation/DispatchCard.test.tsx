// l10n-allow-file: test fixtures.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { DispatchCard } from "./DispatchCard";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";

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

const item: AcpmuxActivity = {
  kind: "tool",
  text: "acp.dispatch",
  tool: {
    id: "dispatch-17",
    title: "acp.dispatch",
    status: "completed",
    inputSummary: JSON.stringify({ title: "Diff viewer on the right", brief: "Move the diff viewer right." }),
  },
};

test("dispatch card expands the brief and never renders a shell block", async () => {
  const container = await render(
    <DispatchCard
      item={item}
      call={{
        kind: "dispatch",
        briefId: "b-17",
        title: "Diff viewer on the right",
        text: "Move the diff viewer right.",
        to: "cx3-s14-header",
        host: "cmux16",
      }}
    />,
  );
  const row = container.querySelector<HTMLButtonElement>(".cv-dispatch__line")!;
  expect(row.textContent).toContain("Sent to 'Diff viewer on the right' → cx3-s14-header · cmux16");
  expect(row.getAttribute("aria-expanded")).toBe("false");
  expect(container.querySelector(".cv-shell")).toBeNull();
  await act(async () => row.click());
  expect(row.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector(".cv-dispatch__text")?.textContent).toBe("Move the diff viewer right.");
});

test("a report row links back to its brief and carries sender attribution", async () => {
  const container = await render(
    <DispatchCard
      item={{ ...item, tool: { ...item.tool!, id: "report-17", title: "acp.report" } }}
      call={{
        kind: "report",
        briefId: "b-17",
        title: "Diff viewer on the right",
        from: "deepseek",
        summary: "Merged.",
      }}
    />,
  );
  const row = container.querySelector(".cv-dispatch")!;
  expect(row.getAttribute("data-from")).toBe("deepseek");
  expect(row.querySelector('a[href="#brief-b-17"]')?.textContent).toBe("Diff viewer on the right");
  await act(async () => (row.querySelector("button") as HTMLButtonElement).click());
  expect(row.querySelector('a[href="#brief-b-17"]')?.textContent).toBe("Diff viewer on the right");
});
