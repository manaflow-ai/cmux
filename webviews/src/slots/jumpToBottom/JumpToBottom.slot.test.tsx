// l10n-allow-file: the button's label is supplied by the pane's string table.
// The Jump to latest mark is the theme slot `chat.jumpToBottom` (slots/jumpToBottom): its default draws
// the markup the button drew before the slot, element for element, so the default look is unchanged;
// each built-in variant draws inside the same button, hidden from readers, and the button keeps its label.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { settleReact } from "../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import slotsSchema from "../../../../schemas/theme/slots.json";
import { JumpToLatest } from "../../agent-session/acpmux/VirtualTranscript";
import { ArrowDown } from "../../agent-session/acpmux/conversation/icons";
import { configureThemeSlots, slotVariantIds } from "../registry";
import { JUMP_TO_BOTTOM_VARIANTS, jumpToBottomSlot, registerJumpToBottomVariants } from "./index";

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
  // Another test file in the same run may have reset the registry (registry.test.tsx): put ours back.
  registerJumpToBottomVariants();
});

afterEach(async () => {
  act(() => root?.unmount());
  configureThemeSlots(undefined);
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

const button = () => container.querySelector<HTMLButtonElement>("button.acpmux-jump-latest:not(.acpmux-jump-up)")!;

test("cmux registers exactly the variants slots.json lists, default first", () => {
  const spec = slotsSchema.slots.find((entry) => entry.id === "chat.jumpToBottom")!;
  expect(slotVariantIds(jumpToBottomSlot.id)).toEqual(spec.variants.map((variant) => variant.id));
  expect(Object.keys(JUMP_TO_BOTTOM_VARIANTS)[0]).toBe(spec.defaultVariant);
});

test("the default variant draws the pre-slot arrow exactly", () => {
  act(() => root!.render(<JumpToLatest shown working={false} lift={0} onJump={() => {}} />));
  const expected = dom!.window.document.getElementById("expected")!;
  const other = createRoot(expected);
  // The button's child before the slot, verbatim.
  act(() =>
    other.render(
      <span className="acpmux-jump-latest__arrow" aria-hidden="true">
        <ArrowDown size={14} />
      </span>,
    ),
  );
  expect(button().innerHTML).toBe(expected.innerHTML);
  act(() => other.unmount());
});

test("every built-in variant draws inside the button, hidden from readers, the label kept", () => {
  for (const id of Object.keys(JUMP_TO_BOTTOM_VARIANTS)) {
    act(() => configureThemeSlots({ "chat.jumpToBottom": id }));
    for (const working of [false, true]) {
      act(() =>
        root!.render(<JumpToLatest key={`${id}-${working}`} shown working={working} lift={0} onJump={() => {}} />),
      );
      const mark = button().querySelector(".acpmux-jump-latest__arrow")!;
      expect(mark.getAttribute("aria-hidden")).toBe("true");
      expect(button().getAttribute("aria-label")).toBeTruthy();
      if (id !== "default") {
        expect(mark.getAttribute("data-variant")).toBe(id);
        if (id !== "nudge") expect(mark.hasAttribute("data-working")).toBe(working);
      }
    }
  }
});

test("an unknown id draws the default arrow", () => {
  act(() => configureThemeSlots({ "chat.jumpToBottom": "sparkles" }));
  act(() => root!.render(<JumpToLatest shown working lift={0} onJump={() => {}} />));
  expect(button().querySelector("[data-variant]")).toBeNull();
  expect(button().querySelector(".acpmux-jump-latest__arrow")).not.toBeNull();
});
