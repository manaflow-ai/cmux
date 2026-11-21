// Theme slots (registry.ts, Slot.tsx): the variant a slot draws comes from the theme look's `slots` map,
// an unknown id or a throwing variant falls back to the default (never a blank slot), and the slot adds
// no commit of its own.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { Profiler, act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import slotsSchema from "../../../schemas/theme/slots.json";
import {
  configureThemeSlots,
  defineSlot,
  registerSlotVariant,
  resetSlotsForTest,
  selectedSlotVariant,
  slotFailure,
  slotVariantIds,
} from "./registry";
import { Slot } from "./Slot";
import {
  registerThinkingIndicatorVariants,
  thinkingIndicatorSlot,
  THINKING_INDICATOR_VARIANTS,
} from "./thinkingIndicator";
import { applyAgentTheme } from "../agent-session/shared/theme";
import { settleReact } from "../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "CustomEvent",
  "IS_REACT_ACT_ENVIRONMENT",
  "cmuxSlots",
  "cmuxTheme",
];

const slot = thinkingIndicatorSlot;
const props = { label: "Thinking", verbs: ["Thinking"], elapsedMs: 0 };
const theme = (slots?: Record<string, string>) =>
  ({ isDark: true, shadow: "none", slots }) as unknown as Parameters<typeof applyAgentTheme>[0];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    CustomEvent: dom.window.CustomEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  delete scope.cmuxSlots;
  delete scope.cmuxTheme;
  resetSlotsForTest();
  registerThinkingIndicatorVariants();
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(async () => {
  act(() => root?.unmount());
  resetSlotsForTest();
  registerThinkingIndicatorVariants();
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

const drawn = () => container.querySelector("[data-variant]")?.getAttribute("data-variant") ?? "default";

test("cmux registers exactly the variants slots.json lists, default first", () => {
  const spec = slotsSchema.slots.find((entry) => entry.id === "chat.thinkingIndicator")!;
  expect(slotVariantIds(slot.id)).toEqual(spec.variants.map((variant) => variant.id));
  expect(Object.keys(THINKING_INDICATOR_VARIANTS)[0]).toBe(spec.defaultVariant);
  expect(slot.defaultVariant).toBe("default");
});

test("a slot needs a schema entry and a dotted id", () => {
  expect(() => defineSlot("chat.noSuchSlot")).toThrow(/no entry/);
  expect(() => registerSlotVariant(slot, "Not Kebab", () => null)).toThrow(/kebab/);
});

test("the theme look's slots map selects the variant; without the field every slot draws its default", () => {
  act(() => applyAgentTheme(theme()));
  act(() => root!.render(<Slot slot={slot} props={props} />));
  expect(drawn()).toBe("default");
  expect(container.querySelector(".cv-shimmer__band")).not.toBeNull();

  act(() => applyAgentTheme(theme({ "chat.thinkingIndicator": "counting-dots" })));
  expect(drawn()).toBe("counting-dots");

  act(() => applyAgentTheme(theme({ "chat.thinkingIndicator": "blocks" })));
  expect(drawn()).toBe("blocks");

  // A later push without `slots` (a host that never sends it) puts the default back.
  act(() => applyAgentTheme(theme()));
  expect(drawn()).toBe("default");
});

test("the shared web theme's slots (window.cmuxTheme.current) select too, on its cmux-theme push", () => {
  act(() => root!.render(<Slot slot={slot} props={props} />));
  expect(drawn()).toBe("default");
  scope.cmuxTheme = { current: { slots: { "chat.thinkingIndicator": "caret" } } };
  act(() => {
    dom!.window.dispatchEvent(new dom!.window.CustomEvent("cmux-theme"));
  });
  expect(drawn()).toBe("caret");
});

test("an unknown variant id anywhere falls through to the next source, then the default", () => {
  expect(selectedSlotVariant(slot, { theme: { "chat.thinkingIndicator": "sparkles" } })).toBe("default");
  expect(
    selectedSlotVariant(slot, {
      overrides: { "chat.thinkingIndicator": "sparkles" },
      stored: {},
      theme: { "chat.thinkingIndicator": "pulse" },
    }),
  ).toBe("pulse");
  act(() => configureThemeSlots({ "chat.thinkingIndicator": "sparkles" }));
  act(() => root!.render(<Slot slot={slot} props={props} />));
  expect(drawn()).toBe("default");
  expect(container.textContent).toContain("Thinking");
});

test("the gallery or dev override wins over the theme", () => {
  expect(
    selectedSlotVariant(slot, {
      overrides: { "chat.thinkingIndicator": "caret" },
      stored: { "chat.thinkingIndicator": "blocks" },
      theme: { "chat.thinkingIndicator": "pulse" },
    }),
  ).toBe("caret");
  expect(selectedSlotVariant(slot, { overrides: {}, stored: { "chat.thinkingIndicator": "blocks" }, theme: {} })).toBe(
    "blocks",
  );
});

test("a variant that throws draws the default in its place, and the rest of the tree keeps drawing", () => {
  const warn = console.warn;
  const error = console.error;
  console.warn = () => {};
  console.error = () => {};
  try {
    registerSlotVariant(slot, "broken", () => {
      throw new Error("a theme pack bug");
    });
    act(() => configureThemeSlots({ "chat.thinkingIndicator": "broken" }));
    act(() =>
      root!.render(
        <div>
          <span id="before">before</span>
          <Slot slot={slot} props={props} />
          <span id="after">after</span>
        </div>,
      ),
    );
    expect(drawn()).toBe("default");
    expect(container.querySelector(".cv-status-verb__word")?.textContent).toBe("Thinking");
    expect(container.querySelector("#before")).not.toBeNull();
    expect(container.querySelector("#after")).not.toBeNull();
    expect(slotFailure(slot.id)?.variant).toBe("broken");

    // Choosing a working variant afterwards draws it: the failure belongs to the broken one alone.
    act(() => configureThemeSlots({ "chat.thinkingIndicator": "pulse" }));
    expect(drawn()).toBe("pulse");
  } finally {
    console.warn = warn;
    console.error = error;
  }
});

test("a slot commits only when its selection changes, never on its own", () => {
  let commits = 0;
  const tree = () => (
    <Profiler id="slot" onRender={() => void (commits += 1)}>
      <Slot slot={slot} props={props} />
    </Profiler>
  );
  act(() => root!.render(tree()));
  const mounted = commits;
  // The same theme pushed again (every bridge push resends the look) changes nothing.
  act(() => configureThemeSlots(undefined));
  act(() => configureThemeSlots(undefined));
  expect(commits).toBe(mounted);
  act(() => configureThemeSlots({ "chat.thinkingIndicator": "pulse" }));
  expect(commits).toBe(mounted + 1);
  act(() => configureThemeSlots({ "chat.thinkingIndicator": "pulse" }));
  expect(commits).toBe(mounted + 1);
});
