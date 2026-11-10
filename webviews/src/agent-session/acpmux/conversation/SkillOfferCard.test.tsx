// l10n-allow-file: test fixtures.
// The skill offer card (SkillOfferCard.tsx): its draft, Save with the draft, Edit then Save with the
// edited values, Not now, one key per action with focus inside, the daemon's error inline, the
// one-line note once settled, and no buttons without `onResolve`.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SkillOfferCard } from "./SkillOfferCard";
import {
  settleSkillOffer,
  skillOfferFromRecord,
  skillRequestFailed,
  type SkillAction,
  type SkillDraft,
} from "./skillOffer";

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
    "Event",
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
    Event: dom.window.Event,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
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

const BODY = "## Steps\n\n1. Install.\n2. Run bun test.\n\n## Commands\n\n- `bun test`";
const DRAFT: SkillDraft = {
  name: "run-webview-tests",
  description: "Use when asked to run the webview tests.",
  body: BODY,
};
const OFFER = skillOfferFromRecord({ offerId: "s1", ...DRAFT, count: 3, chats: [], drafted: "harness" })!;

const press = async (target: Element, key: string, init: KeyboardEventInit = {}) =>
  act(async () => {
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
const click = async (target: Element) =>
  act(async () => {
    (target as HTMLElement).click();
  });
const button = (container: HTMLElement, label: string) =>
  [...container.querySelectorAll<HTMLButtonElement>(".cv-skill__foot button")].find(
    (element) => element.textContent === label,
  )!;
/// Types into a React-controlled field: the native value setter, then the event React listens to.
const type = async (field: HTMLInputElement | HTMLTextAreaElement, value: string) =>
  act(async () => {
    const proto = Object.getPrototypeOf(field) as object;
    Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(field, value);
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });

test("the card draws the question, the draft and its steps behind a disclosure, and takes no focus", async () => {
  const container = await render(<SkillOfferCard offer={OFFER} onResolve={() => {}} />);
  expect(container.querySelector(".cv-skill__question")?.textContent).toBe(
    "You've done this 3 times. Save it as a skill?",
  );
  expect(container.querySelector(".cv-skill__name")?.textContent).toBe("run-webview-tests");
  expect(container.querySelector(".cv-skill__description")?.textContent).toBe(DRAFT.description);
  expect(container.querySelector(".cv-skill__source")?.textContent).toBe(BODY);
  const disclose = container.querySelector<HTMLButtonElement>(".cv-skill__disclose")!;
  expect(disclose.getAttribute("aria-expanded")).toBe("false");
  await click(disclose);
  expect(disclose.getAttribute("aria-expanded")).toBe("true");
  expect(disclose.textContent).toBe("Hide steps");
  expect([...container.querySelectorAll(".cv-skill__foot button")].map((b) => b.textContent)).toEqual([
    "Not now",
    "Edit",
    "Save",
  ]);
  expect(container.ownerDocument.activeElement).toBe(container.ownerDocument.body);
});

test("Save sends the draft as drawn; Not now sends a dismissal", async () => {
  const calls: [SkillAction, SkillDraft | undefined][] = [];
  const container = await render(
    <SkillOfferCard offer={OFFER} onResolve={(action, draft) => calls.push([action, draft])} />,
  );
  await click(button(container, "Save"));
  await click(button(container, "Not now"));
  expect(calls).toEqual([
    ["save", DRAFT],
    ["dismiss", undefined],
  ]);
});

test("Edit turns the draft into fields; Save sends the edited values, and an invalid name holds it", async () => {
  const calls: [SkillAction, SkillDraft | undefined][] = [];
  const container = await render(
    <SkillOfferCard offer={OFFER} onResolve={(action, draft) => calls.push([action, draft])} />,
  );
  await click(button(container, "Edit"));
  const [name, description] = [...container.querySelectorAll<HTMLInputElement>("input.cv-skill__input")];
  const body = container.querySelector<HTMLTextAreaElement>("textarea.cv-skill__input")!;
  expect(container.ownerDocument.activeElement).toBe(name);
  expect([name.value, description.value, body.value]).toEqual([DRAFT.name, DRAFT.description, DRAFT.body]);
  await type(name, "Bad Name");
  expect(name.getAttribute("aria-invalid")).toBe("true");
  expect(container.querySelector(".cv-skill__hint")?.textContent).toBe(
    "Lowercase letters, digits and hyphens, up to 64",
  );
  expect(button(container, "Save").disabled).toBe(true);
  await press(name, "Enter", { metaKey: true });
  expect(calls).toEqual([]);
  await type(name, "run-tests");
  await type(description, "  When the tests need a run.  ");
  await type(body, "1. Run them.");
  await click(button(container, "Save"));
  expect(calls).toEqual([
    ["save", { name: "run-tests", description: "When the tests need a run.", body: "1. Run them." }],
  ]);
  // Escape in a field drops the edits and shows the draft again.
  await press(body, "Escape");
  expect(container.querySelector("textarea")).toBeNull();
  expect(container.querySelector(".cv-skill__name")?.textContent).toBe("run-webview-tests");
});

test("with focus in the card, Return saves, e edits, d and Escape are Not now", async () => {
  const calls: SkillAction[] = [];
  const container = await render(<SkillOfferCard offer={OFFER} onResolve={(action) => calls.push(action)} />);
  const draft = container.querySelector<HTMLElement>("[data-skill-draft]")!;
  expect(draft.tabIndex).toBe(0);
  await press(draft, "Enter");
  await press(draft, "d");
  await press(draft, "Escape");
  expect(calls).toEqual(["save", "dismiss", "dismiss"]);
  await press(draft, "e");
  expect(container.querySelector("textarea")).not.toBeNull();
});

test("a failed save shows the daemon's message and keeps the buttons", async () => {
  const failed = skillRequestFailed(OFFER, "a skill named run-webview-tests already exists");
  const container = await render(<SkillOfferCard offer={failed} onResolve={() => {}} />);
  expect(container.querySelector(".cv-skill__error")?.textContent).toBe(
    "a skill named run-webview-tests already exists",
  );
  expect([...container.querySelectorAll<HTMLButtonElement>(".cv-skill__foot button")].every((b) => !b.disabled)).toBe(
    true,
  );
});

test("a settled offer folds to its one-line note", async () => {
  const done = settleSkillOffer(OFFER, {
    action: "save",
    name: "run-tests",
    path: ".claude/skills/run-tests/SKILL.md",
  });
  const container = await render(<SkillOfferCard offer={done} onResolve={() => {}} />);
  expect(container.querySelector(".cv-skill")?.getAttribute("data-settled")).toBe("true");
  expect(container.querySelector(".cv-skill__body")?.hasAttribute("inert")).toBe(true);
  expect(container.querySelector(".cv-skill__note")?.textContent).toBe(
    "Saved skill run-tests.claude/skills/run-tests/SKILL.md",
  );
  expect(container.querySelector(".cv-skill__path")?.textContent).toBe(".claude/skills/run-tests/SKILL.md");
  const dismissed = settleSkillOffer(OFFER, { action: "dismiss" });
  await act(async () => root!.render(<SkillOfferCard offer={dismissed} onResolve={() => {}} />));
  expect(container.querySelector(".cv-skill__note")?.textContent).toBe("Not now: this won't be offered again");
});

test("without onResolve (a replay or a guest) the draft draws with no buttons", async () => {
  const container = await render(<SkillOfferCard offer={OFFER} />);
  expect(container.querySelector(".cv-skill__name")?.textContent).toBe("run-webview-tests");
  expect(container.querySelector(".cv-skill__foot")).toBeNull();
  expect(container.querySelector<HTMLElement>("[data-skill-draft]")?.hasAttribute("tabindex")).toBe(false);
});
