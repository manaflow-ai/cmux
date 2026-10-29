// The transcript's sub-session rows are one-line disclosures: the prompt opens as Markdown below
// the anchored line, while adjacent starts collapse into one group row.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { setPaneLanguage } from "../src/agent-session/acpmux/i18n";
import { SubsessionCallCard } from "../src/agent-session/acpmux/conversation/SubsessionCallCard";
import { SubsessionContext, SubsessionStore } from "../src/agent-session/acpmux/subagents/subsessions";
import {
  resetTranscriptDisclosure,
  TranscriptDisclosureProvider,
} from "../src/agent-session/acpmux/conversation/transcriptDisclosure";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
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
  resetTranscriptDisclosure();
  setPaneLanguage("en");
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

test("collapsed groups follow child sessions after their start calls finish", async () => {
  const container = installDom();
  const store = new SubsessionStore();
  const names = ["msg-fold", "picker-polish", "cloud-demo"];
  const entries = names.map((name) => ({ call: start(name), tool: tool(name) }));
  const setChild = (change: Partial<AcpmuxSessionEntry>) =>
    store.set(
      names.map(
        (name, index) =>
          ({
            sessionId: `${name}-id`,
            startedBy: "parent",
            status: "idle",
            lane: "idle",
            ...(index === 0 ? change : {}),
          }) as AcpmuxSessionEntry,
      ),
    );
  setChild({ lane: "working" });
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => {} }}>
        <SubsessionCallCard group={entries} />
      </SubsessionContext.Provider>,
    ),
  );
  const status = () => container.querySelector(".cv-disclosure__status")!;
  expect(status().textContent).toContain("Working");
  expect(status().querySelector("svg")).not.toBeNull();
  await act(async () => setChild({ lane: "input" }));
  expect(status().textContent).toContain("1 waiting");
  expect(status().querySelector("svg")).toBeNull();
  await act(async () => setChild({ lane: "failed" }));
  expect(status().textContent).toContain("1 failed");
  await act(async () => setChild({ lane: "failed", retry: { attempt: 1, of: 4 } }));
  expect(status().textContent).toContain("Working");
  expect(status().textContent).not.toContain("failed");
  expect(status().querySelector("svg")).not.toBeNull();
  await act(async () => setChild({ lane: "working", waitsForSlot: true }));
  expect(status().textContent).toContain("1 waiting");
  await act(async () => setChild({ lane: "idle" }));
  expect(status().textContent).toBe("Done");
  expect(status().querySelector("svg")).toBeNull();
});

test("single and grouped disclosures keep independent choices across virtualized remounts", async () => {
  const container = installDom();
  root = createRoot(container);
  const entries = ["msg-fold", "picker-polish", "cloud-demo"].map((name) => ({ call: start(name), tool: tool(name) }));
  const render = async (sessionId = "parent") =>
    act(async () =>
      root!.render(
        <TranscriptDisclosureProvider sessionId={sessionId}>
          <SubsessionCallCard call={start("single")} tool={tool("single")} />
          <SubsessionCallCard call={start("other")} tool={tool("other")} />
          <SubsessionCallCard group={entries} />
        </TranscriptDisclosureProvider>,
      ),
    );
  const toggles = () => [...container.querySelectorAll<HTMLButtonElement>(".cv-disclosure__toggle")];
  await render();
  await act(async () => toggles()[0]!.click());
  await act(async () => toggles()[2]!.click());
  await act(async () => toggles()[3]!.click());
  expect(toggles().map((button) => button.getAttribute("aria-expanded"))).toEqual([
    "true",
    "false",
    "true",
    "true",
    "false",
    "false",
  ]);
  await act(async () => root!.unmount());
  root = createRoot(container);
  await render();
  expect(toggles().map((button) => button.getAttribute("aria-expanded"))).toEqual([
    "true",
    "false",
    "true",
    "true",
    "false",
    "false",
  ]);
  expect(container.querySelector(".cv-subsession__markdown strong")?.textContent).toBe("full");
  await act(async () => root!.render(null));
  await render("different-parent");
  expect(toggles().map((button) => button.getAttribute("aria-expanded"))).toEqual(["false", "false", "false"]);
});

test("started labels preserve the localized space and name position", async () => {
  const container = installDom();
  root = createRoot(container);
  for (const [language, expected] of [
    ["en", "Started sub-session tests"],
    ["de", "Untersitzung tests gestartet"],
    ["ja", "サブセッション tests を開始"],
    ["tr", "tests alt oturumu başlatıldı"],
  ]) {
    await act(async () => {
      setPaneLanguage(language!);
      root!.render(<SubsessionCallCard call={start("tests")} tool={tool("tests")} />);
    });
    expect(container.querySelector(".cv-disclosure__label")?.textContent).toBe(expected!);
  }
});
