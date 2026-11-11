// l10n-allow-file: the status copy is supplied by the pane's string table.
// The live line's thinking indicator is the theme slot `chat.thinkingIndicator` (slots/thinkingIndicator):
// its default draws the markup the line drew before the slot, element for element, so the default look
// is unchanged; each built-in variant draws in the same `<output>` with the same words.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Thinking } from "./Thinking";
import { ShimmerText } from "./ShimmerText";
import { configureThemeSlots } from "../../../slots/registry";
import { THINKING_INDICATOR_VARIANTS } from "../../../slots/thinkingIndicator";
import { LONG_THINK_MS } from "../../../slots/thinkingIndicator/CountingDots";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main><main id=expected></main></body></html>", {
    url: "http://localhost/",
  });
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
  configureThemeSlots(undefined);
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

/** The decorative branch of Thinking.tsx before the slot, verbatim: what the default must still draw. */
function PreSlotDecorative({ label, verbs, elapsed }: { label: string; verbs: string[]; elapsed?: string }) {
  const verbSizes = verbs.map((word, index) => (
    <span key={index} className="cv-status-verb__size" data-text={word} aria-hidden="true" inert />
  ));
  const decorative = true;
  return (
    <ShimmerText
      text={label}
      baseText={
        <span className="cv-status-verb">
          {verbSizes}
          <span className="cv-status-verb__word">{label}</span>
        </span>
      }
      lit={
        <>
          <span className={`cv-shimmer__lit-label${decorative ? " cv-status-verb" : ""}`} data-text={label}>
            {decorative && verbSizes}
          </span>
          {elapsed && <span className="cv-shimmer__lit-time" data-text={elapsed} />}
        </>
      }
    />
  );
}

test("the default variant draws the pre-slot live line's markup exactly", () => {
  act(() => root!.render(<Thinking since={0} now={() => 2_400} />));
  const output = container.querySelector(".cv-thinking")!;
  const elapsed = container.querySelector(".cv-worked__time")?.textContent || undefined;
  expect(elapsed).toBeTruthy();
  const expected = dom!.window.document.getElementById("expected")!;
  const other = createRoot(expected);
  act(() => other.render(<PreSlotDecorative label="Thinking" verbs={["Thinking"]} elapsed={elapsed} />));
  expect(output.innerHTML).toBe(expected.innerHTML);
  act(() => other.unmount());
});

// The live line is one shimmer from the prompt to the last step (Leo, 2026-11-01: "it should just keep
// going", "and shouldn't flicker"): with the default look, the band element under "Thinking" is the
// same element under a named step and under "Thinking" again. The slot drew its default through
// `<Slot>` and a step through the line's own `<ShimmerText>`, two component types at one place, so
// React mounted a new band at each change (test/transcript-live-line-continuous-browser.test.ts read
// 5 band elements in a turn of 6 steps).
test("the default look keeps one shimmer band from Thinking through a step and back", () => {
  const band = () => container.querySelector(".cv-shimmer__band");
  act(() => root!.render(<Thinking since={0} now={() => 2_400} />));
  const first = band();
  expect(first === null).toBe(false);
  expect(container.querySelector(".cv-status-verb__word")?.textContent).toBe("Thinking");
  act(() => root!.render(<Thinking since={0} now={() => 2_400} doing="Read App.tsx" doingAt={1} />));
  expect(container.querySelector(".cv-shimmer__lit-label")?.getAttribute("data-text")).toBe("Read App.tsx");
  expect(band() === first).toBe(true);
  act(() => root!.render(<Thinking since={0} now={() => 2_400} />));
  expect(container.querySelector(".cv-status-verb__word")?.textContent).toBe("Thinking");
  expect(band() === first).toBe(true);
});

// Where the slot itself draws the default (the fallback of a variant that threw, the gallery), it is
// the same markup.
test("the default variant's own component draws the pre-slot markup too", () => {
  const Default = THINKING_INDICATOR_VARIANTS.default;
  act(() =>
    root!.render(<Default label="Thinking" verbs={["Thinking", "Pondering"]} elapsed="2s" elapsedMs={2_400} />),
  );
  const expected = dom!.window.document.getElementById("expected")!;
  const other = createRoot(expected);
  act(() => other.render(<PreSlotDecorative label="Thinking" verbs={["Thinking", "Pondering"]} elapsed="2s" />));
  expect(container.innerHTML).toBe(expected.innerHTML);
  act(() => other.unmount());
});

test("a running call still draws its own shimmer, not the slot", () => {
  act(() => configureThemeSlots({ "chat.thinkingIndicator": "counting-dots" }));
  act(() => root!.render(<Thinking since={0} now={() => 1_000} doing="Read App.tsx" doingAt={1} />));
  expect(container.querySelector("[data-variant]")).toBeNull();
  expect(container.querySelector(".cv-shimmer__lit-label")?.getAttribute("data-text")).toBe("Read App.tsx");
});

test("every built-in variant draws the word in the line's output, its mark hidden from readers", () => {
  for (const id of Object.keys(THINKING_INDICATOR_VARIANTS)) {
    act(() => configureThemeSlots({ "chat.thinkingIndicator": id }));
    act(() => root!.render(<Thinking key={id} since={0} now={() => 2_400} />));
    const output = container.querySelector("output.cv-thinking")!;
    expect(output.getAttribute("aria-label")).toBe("Thinking");
    expect(output.querySelector(".cv-status-verb__word")?.textContent).toBe("Thinking");
    if (id !== "default") {
      expect(output.querySelector("[data-variant]")?.getAttribute("data-variant")).toBe(id);
      expect(output.querySelector(".slot-thinking__mark")?.getAttribute("aria-hidden")).toBe("true");
    }
  }
});

test("counting dots: three dots, and a fourth once the turn has thought long", () => {
  act(() => configureThemeSlots({ "chat.thinkingIndicator": "counting-dots" }));
  act(() => root!.render(<Thinking key="early" since={0} now={() => LONG_THINK_MS - 1_000} />));
  expect(container.querySelectorAll(".slot-thinking__dot")).toHaveLength(4);
  expect(container.querySelector(".slot-thinking__dots")?.hasAttribute("data-long")).toBe(false);
  act(() => root!.render(<Thinking key="long" since={0} now={() => LONG_THINK_MS + 1_000} />));
  expect(container.querySelector(".slot-thinking__dots")?.hasAttribute("data-long")).toBe(true);
});
