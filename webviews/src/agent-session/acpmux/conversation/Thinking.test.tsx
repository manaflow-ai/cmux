// l10n-allow-file: the status copy is supplied by the pane's string table.
// The first streamed answer token turns the live line to "Writing" in the same frame, before that
// frame paints, so "Thinking" never flashes under the answer. The line never hides mid-turn.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { Thinking } from "./Thinking";
import { WorkingFor } from "./WorkingFor";
import { StatusVerbContext } from "../statusVerbs";
import { WaitingOnContext } from "./waitingOn";
import { setChatDisplay } from "../chatDisplay";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(() => {
  act(() => root?.unmount());
  setChatDisplay({});
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

test("the live line stays shown and reads Writing from the first streamed answer token", () => {
  act(() => root!.render(<Thinking quietKey={undefined} liveState="writing" />));
  expect(container.querySelector(".cv-worked")?.classList.contains("is-quiet")).toBe(false);
  expect(container.querySelector(".cv-worked")?.textContent).toContain("Thinking");

  act(() => root!.render(<Thinking quietKey="assistant:1" liveState="writing" />));
  expect(container.querySelector(".cv-worked")?.classList.contains("is-quiet")).toBe(false);
  expect(container.querySelector(".cv-worked")?.textContent).toContain("Writing");

  act(() => root!.render(<Thinking quietKey="assistant:2" liveState="writing" />));
  expect(container.querySelector(".cv-worked")?.classList.contains("is-quiet")).toBe(false);
});

test("a send in flight names who it goes to, on either live line", () => {
  act(() => root!.render(<Thinking doing="acpmux send coord 'hi'" doingShell sendTo="coord" />));
  expect(container.querySelector(".cv-worked")?.textContent).toContain("Sending message to coord");
  expect(container.textContent).not.toContain("acpmux send");
  const row: AcpmuxRow = {
    id: "working",
    version: 1,
    at: Date.now(),
    kind: "working",
    doing: "acpmux send coord 'hi'",
    doingCommand: true,
    doingSendTo: "coord",
  };
  act(() => root!.render(<WorkingFor row={row} />));
  expect(container.querySelector(".cv-worked")?.textContent).toContain("Sending message to coord");
  expect(container.textContent).not.toContain("acpmux send");
  expect(container.querySelector(".cv-worked__glyph")).toBeNull();
});

test("the live line uses a configured rotating verb", () => {
  act(() =>
    root!.render(
      <StatusVerbContext.Provider value={{ mode: "custom", verbs: ["Planning", "Reading"] }}>
        <Thinking since={0} now={() => 2_400} />
      </StatusVerbContext.Provider>,
    ),
  );
  const status = container.querySelector(".cv-thinking")!;
  expect(status.textContent).toContain("Reading");
  // Rotating copy is decorative: the implicit output live region keeps one stable accessible name
  // and never announces every cadence tick. Typed states below keep their factual output.
  expect(status.getAttribute("aria-label")).toBe("Thinking");
  expect(status.getAttribute("aria-live")).toBe("off");
});

test("thinking-only configuration keeps the traditional label", () => {
  act(() =>
    root!.render(
      <StatusVerbContext.Provider value={{ mode: "thinking", verbs: ["Thinking"] }}>
        <Thinking since={0} now={() => 60_000} />
      </StatusVerbContext.Provider>,
    ),
  );
  expect(container.querySelector(".cv-thinking")?.textContent).toContain("Thinking");
  expect(container.querySelector(".cv-thinking")?.textContent).not.toContain("Planning");
});

test("a typed wait keeps precedence over rotating verbs", () => {
  act(() =>
    root!.render(
      <StatusVerbContext.Provider value={{ mode: "custom", verbs: ["Planning"] }}>
        <WaitingOnContext.Provider value="permission">
          <Thinking since={0} now={() => 60_000} />
        </WaitingOnContext.Provider>
      </StatusVerbContext.Provider>,
    ),
  );
  expect(container.querySelector("[data-waiting=permission]")).not.toBeNull();
  expect(container.textContent).not.toContain("Planning");
});

test("saved display settings update an already mounted live line", () => {
  act(() => {
    setChatDisplay({ "agentPane.display.statusVerbs.mode": "rotate" });
    root!.render(<Thinking since={0} now={() => 2_400} />);
  });
  expect(container.querySelector(".cv-thinking")?.textContent).toContain("Thinking");
  act(() => setChatDisplay({ "agentPane.display.statusVerbs.mode": "thinking" }));
  expect(container.querySelector(".cv-thinking")?.textContent).toContain("Thinking");
  act(() =>
    setChatDisplay({
      "agentPane.display.statusVerbs.mode": "custom",
      "agentPane.display.statusVerbs.custom": "Planning, Reading",
    }),
  );
  expect(container.querySelector(".cv-thinking")?.textContent).toContain("Reading");
});

test("unreachable and subagent states remain factual with custom verbs", () => {
  act(() =>
    setChatDisplay({
      "agentPane.display.statusVerbs.mode": "custom",
      "agentPane.display.statusVerbs.custom": "Imagining",
    }),
  );
  act(() => root!.render(<Thinking retry={{ attempt: 2, maxRetries: 5, errorStatus: 503 }} />));
  expect(container.querySelector("[data-retrying]")).not.toBeNull();
  expect(container.textContent).not.toContain("Imagining");
  act(() => root!.render(<Thinking liveState="subagents" liveAgents={2} />));
  expect(container.textContent).toContain("Waiting on 2 subagents");
  expect(container.textContent).not.toContain("Imagining");
});

test("a live activity disclosure exposes a labelled button and preserves its toggle action", () => {
  let toggles = 0;
  const onToggle = () => {
    toggles += 1;
  };
  act(() => root!.render(<Thinking doing="Read retry.ts" disclosure={{ expanded: false, onToggle }} />));
  const button = container.querySelector<HTMLButtonElement>(".cv-live-disclosure__toggle")!;
  expect(button.getAttribute("aria-label")).toBe("Read retry.ts");
  expect(button.getAttribute("aria-expanded")).toBe("false");
  act(() => button.click());
  expect(toggles).toBe(1);
  act(() => root!.render(<Thinking doing="Read retry.ts" disclosure={{ expanded: true, onToggle }} />));
  expect(button.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector("button button")).toBeNull();
});

test("gateway retries keep the live activity disclosure available", () => {
  let toggles = 0;
  act(() =>
    root!.render(
      <Thinking
        doing="Run tests"
        retry={{ attempt: 2, maxRetries: 5, errorStatus: 503 }}
        disclosure={{
          expanded: false,
          onToggle: () => {
            toggles += 1;
          },
        }}
      />,
    ),
  );
  const toggle = container.querySelector<HTMLButtonElement>(".cv-live-disclosure__toggle");
  expect(toggle).not.toBeNull();
  act(() => toggle!.click());
  expect(toggles).toBe(1);
  expect(container.querySelector("[data-retrying]")).not.toBeNull();
});
