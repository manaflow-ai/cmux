// The six slots after the first two (schemas/theme/slots.json: chat.sendTransition, chat.receiveTransition,
// chat.side, row.hover, composer.caret, toast.enter): each one's default draws what its surface drew
// before it had a slot, element for element, so turning the slots on changes nothing a person sees.
// An unknown variant id draws that default too, and a theme pack's variant draws in its place.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import slotsSchema from "../../../schemas/theme/slots.json";
import { PresentationContext } from "../agent-session/acpmux/conversation/presentationContextModel";
import { settleReact } from "../../test/support/domTeardown";
import { configureThemeSlots, registerSlotVariant, slotVariantIds, type SlotDefinition } from "./registry";
import { Slot } from "./Slot";
import { composerCaretSlot, COMPOSER_CARET_VARIANTS, registerComposerCaretVariants } from "./composerCaret";
import {
  receiveTransitionSlot,
  RECEIVE_TRANSITION_VARIANTS,
  registerReceiveTransitionVariants,
} from "./receiveTransition";
import { registerRowHoverVariants, rowHoverSlot, ROW_HOVER_VARIANTS } from "./rowHover";
import { registerSendTransitionVariants, sendTransitionSlot, SEND_TRANSITION_VARIANTS } from "./sendTransition";
import { registerSideVariants, sideSlot, SIDE_VARIANTS } from "./side";
import { registerToastEnterVariants, toastEnterSlot, TOAST_ENTER_VARIANTS } from "./toastEnter";

let dom: JSDOM | undefined;
let roots: Root[] = [];
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

function registerAll(): void {
  registerSendTransitionVariants();
  registerReceiveTransitionVariants();
  registerSideVariants();
  registerRowHoverVariants();
  registerComposerCaretVariants();
  registerToastEnterVariants();
}

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // Another test file in the same run may have reset the registry (registry.test.tsx): put ours back.
  registerAll();
});

afterEach(async () => {
  act(() => {
    for (const root of roots) root.unmount();
  });
  roots = [];
  configureThemeSlots(undefined);
  registerAll();
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

/** The HTML `node` draws. */
function html(node: ReactNode): string {
  const host = dom!.window.document.createElement("div");
  dom!.window.document.body.append(host);
  const root = createRoot(host);
  roots.push(root);
  act(() => root.render(node));
  return host.innerHTML;
}

const words = <p className="cv-prompt-text">Fix the sidebar</p>;

type Case = {
  slot: SlotDefinition<never>;
  variants: Record<string, unknown>;
  /** The slot as its host draws it now. */
  slotted: ReactNode;
  /** What the host drew in its place before the slot, verbatim. */
  before: ReactNode;
};

const CASES: Case[] = [
  {
    // UserBubble.tsx
    slot: sendTransitionSlot as SlotDefinition<never>,
    variants: SEND_TRANSITION_VARIANTS,
    slotted: <Slot slot={sendTransitionSlot} props={{ children: words }} />,
    before: <div className="ui-glass cv-user__bubble selectable">{words}</div>,
  },
  {
    // MessageRow.tsx, the transcript presentation: the reply bare.
    slot: receiveTransitionSlot as SlotDefinition<never>,
    variants: RECEIVE_TRANSITION_VARIANTS,
    slotted: <Slot slot={receiveTransitionSlot} props={{ children: words, streaming: true }} />,
    before: words,
  },
  {
    // MessageRow.tsx, the Messages presentation: the reply in the prompt glass.
    slot: receiveTransitionSlot as SlotDefinition<never>,
    variants: RECEIVE_TRANSITION_VARIANTS,
    slotted: (
      <PresentationContext.Provider value="messages">
        <Slot slot={receiveTransitionSlot} props={{ children: words, streaming: false }} />
      </PresentationContext.Provider>
    ),
    before: <div className="cv-user__bubble ui-glass cv-assistant-bubble">{words}</div>,
  },
  {
    // BtwAside.tsx
    slot: sideSlot as SlotDefinition<never>,
    variants: SIDE_VARIANTS,
    slotted: <Slot slot={sideSlot} props={{ label: "Side question", pending: true, children: words }} />,
    before: (
      <aside className="acpmux-btw-note" aria-label="Side question" aria-busy={true} aria-live="polite">
        {words}
      </aside>
    ),
  },
  {
    // MessageActions.tsx ReplyActions
    slot: rowHoverSlot as SlotDefinition<never>,
    variants: ROW_HOVER_VARIANTS,
    slotted: <Slot slot={rowHoverSlot} props={{ children: words }} />,
    before: (
      <div className="cv-turn-actions cv-reply-actions" data-transcript-gap="blank">
        {words}
      </div>
    ),
  },
  {
    // ComposerBox.tsx: nothing of its own, the field's caret.
    slot: composerCaretSlot as SlotDefinition<never>,
    variants: COMPOSER_CARET_VARIANTS,
    slotted: <Slot slot={composerCaretSlot} props={{ empty: true }} />,
    before: null,
  },
  {
    // NoticeStack.tsx: the card alone.
    slot: toastEnterSlot as SlotDefinition<never>,
    variants: TOAST_ENTER_VARIANTS,
    slotted: <Slot slot={toastEnterSlot} props={{ kind: "toast", children: words }} />,
    before: words,
  },
];

test("each slot registers exactly the variants slots.json lists, default first", () => {
  for (const { slot, variants } of CASES) {
    const spec = slotsSchema.slots.find((entry) => entry.id === slot.id)!;
    expect(spec).toBeDefined();
    expect(slotVariantIds(slot.id)).toEqual(spec.variants.map((variant) => variant.id));
    expect(Object.keys(variants)[0]).toBe(spec.defaultVariant);
    expect(slot.defaultVariant).toBe("default");
  }
});

test("each default draws what its surface drew before the slot, element for element", () => {
  for (const { slot, slotted, before } of CASES) {
    expect({ slot: slot.id, html: html(slotted) }).toEqual({ slot: slot.id, html: html(before) });
  }
});

test("an unknown variant id draws the default; a registered one draws in its place", () => {
  for (const { slot, slotted, before } of CASES) {
    act(() => configureThemeSlots({ [slot.id]: "sparkles" }));
    expect(html(slotted)).toBe(html(before));

    registerSlotVariant(slot as SlotDefinition<object>, "test-mark", () => <i data-variant="test-mark" />);
    act(() => configureThemeSlots({ [slot.id]: "test-mark" }));
    expect(html(slotted)).toBe('<i data-variant="test-mark"></i>');
    act(() => configureThemeSlots(undefined));
  }
});

test("tab.close is drawn natively: no web variant; next until its native host ships (TabCloseSlot.swift)", () => {
  const shipped = slotsSchema.slots.find((entry) => entry.id === "tab.close");
  const next = slotsSchema.next.some((entry) => entry.id === "tab.close");
  expect(Boolean(shipped) !== next).toBe(true);
  for (const variant of shipped?.variants ?? []) expect(variant.source).toEndWith(".swift");
});
