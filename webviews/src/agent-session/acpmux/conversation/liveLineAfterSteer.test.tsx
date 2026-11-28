// l10n-allow-file: test prompts and replies, not shipped UI.
// A running turn whose newest row is a prompt with nothing after it (a fresh send, or a steer that
// landed mid-turn) still names its wait once nothing comes: "Waiting on the model's first reply 12m",
// never a bare "Thinking" that stays for good (Leo, 2026-11-27: "mango has been "thinking" for an
// inordinate amount of time. i think they're bugged and we need to fix this bug"). Detector for
// cmuxterm-hq docs/handbook/error-with-no-next-step.md.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { Thinking } from "./Thinking";
import { turnView } from "./turns";
import { settleReact } from "../../../../test/support/domTeardown";

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

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const T = 1_800_000_000_000;
const P = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "user", text });
const A = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });

const shapes: Record<string, AcpmuxRow[]> = {
  "a steer that landed after the reply": [
    P("p1", T, "Fix the grid"),
    A("a1", T + 1_000, "Done."),
    P("p2", T + 2_000, "why is this misaligned"),
  ],
  "a fresh prompt": [P("p1", T, "Fix the grid")],
};

/// The live line the transcript draws for `rows`, read `afterMs` past its newest row.
function drawLine(rows: AcpmuxRow[], afterMs: number): { line: AcpmuxRow; text: string } {
  const line = turnView(rows, new Set(), { now: T, working: true }).at(-1)!;
  const now = () => rows.at(-1)!.at + afterMs;
  act(() =>
    root!.render(
      <Thinking
        since={line.untimed ? undefined : line.at}
        untimed={line.untimed}
        turnTotal={line.turnTotal}
        heardAt={line.heardAt}
        heardKey={line.heardKey}
        phaseAt={line.phaseAt}
        liveWait={line.liveWait}
        now={now}
      />,
    ),
  );
  return { line, text: container.querySelector(".cv-worked")?.textContent ?? "" };
}

for (const [name, rows] of Object.entries(shapes)) {
  test(`${name}, then 12 minutes of nothing: the line names its wait and how long, not a bare Thinking`, () => {
    const { line, text } = drawLine(rows, 12 * 60_000);
    expect(line.kind).toBe("thinking");
    expect(line.turnTotal).toBe(true);
    expect(line.heardAt).toBe(rows.at(-1)!.at);
    expect(line.liveWait).toEqual({ kind: "prompt" });
    expect(text).toContain("Waiting on the model");
    expect(text).toContain("12m");
  });

  test(`${name}, a moment later: still Thinking, as any step reads before its silence`, () => {
    const { text } = drawLine(rows, 2_000);
    expect(text).toContain("Thinking");
    expect(text).not.toContain("Waiting");
  });
}
