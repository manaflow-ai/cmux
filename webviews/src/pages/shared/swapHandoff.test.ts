// GRACEFUL-SWAP: a page the host reloads into new web hands its state to the new document, which stays
// invisible until it is the page it was and then shows itself (swapHandoff.ts).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  holdSwapReveal,
  keepAcrossSwap,
  prepareSwap,
  startSwapRestore,
  SWAP_HANDOFF_KEY,
  SWAP_RESTORING_ATTRIBUTE,
  swapRestored,
} from "./swapHandoff";

// jsdom gives a custom scheme an opaque origin with no sessionStorage (WKWebView gives cmux-page:// one),
// so the stand-in page lives on an http origin.
const URL = "http://cmux-page.localhost/settings/index.html#/settings/general";
const page = (body: string) =>
  new JSDOM(`<!doctype html><head></head><body>${body}</body>`, { url: URL, pretendToBeVisual: true })
    .window as unknown as Window;

/** The reload: the new document gets the old one's sessionStorage, as a reload of the same tab does. */
function reload(from: Window, body = ""): Window {
  const next = page(body);
  const handoff = from.sessionStorage.getItem(SWAP_HANDOFF_KEY);
  if (handoff) next.sessionStorage.setItem(SWAP_HANDOFF_KEY, handoff);
  return next;
}

test("a swapped-in page stays invisible until its field holds the draft again, then shows with the caret back", async () => {
  const old = page(`<textarea id="draft"></textarea>`);
  const field = old.document.getElementById("draft") as HTMLTextAreaElement;
  field.value = "half typed draft";
  field.focus();
  field.setSelectionRange(4, 9);
  expect(prepareSwap(old.document)).toBe(true);

  // The new document's app renders a moment later (a read of the draft).
  const next = reload(old);
  startSwapRestore(next.document);
  expect(next.document.documentElement.hasAttribute(SWAP_RESTORING_ATTRIBUTE)).toBe(true);
  next.setTimeout(() => {
    next.document.body.innerHTML = `<textarea id="draft"></textarea>`;
    (next.document.getElementById("draft") as HTMLTextAreaElement).value = "half typed draft";
  }, 60);
  const probe = await swapRestored();
  const restored = next.document.getElementById("draft") as HTMLTextAreaElement;
  expect(next.document.documentElement.hasAttribute(SWAP_RESTORING_ATTRIBUTE)).toBe(false);
  expect(next.document.activeElement).toBe(restored);
  expect([restored.selectionStart, restored.selectionEnd]).toEqual([4, 9]);
  expect(probe?.kept).toBe(true);
  expect(probe?.capped).toBe(false);
});

test("an unkept field's edit and a component's own state come back", async () => {
  let folds: unknown = ["tool-1"];
  const release = keepAcrossSwap(
    "folds",
    () => folds,
    (value) => (folds = value),
  );
  const old = page(`<input id="search" value="">`);
  (old.document.getElementById("search") as HTMLInputElement).value = "theme";
  prepareSwap(old.document);
  folds = [];
  const next = reload(old, `<input id="search" value="">`);
  startSwapRestore(next.document);
  const probe = await swapRestored();
  expect((next.document.getElementById("search") as HTMLInputElement).value).toBe("theme");
  expect(folds).toEqual(["tool-1"]);
  expect(probe?.kept_fields).toBe(true);
  release();
});

test("a busy page and a registered hold keep it invisible until they clear", async () => {
  const old = page(`<main>rows</main>`);
  prepareSwap(old.document);
  const next = reload(old, `<main aria-busy="true"></main>`);
  let chipsRead = false;
  const release = holdSwapReveal(() => (chipsRead ? null : "chips"));
  startSwapRestore(next.document);
  let shown = false;
  void swapRestored().then(() => (shown = true));
  // fixed-wait: proving the reveal stays held means outwaiting it once; no event marks "not yet".
  await new Promise((done) => setTimeout(done, 200));
  expect(shown).toBe(false);
  next.document.querySelector("main")!.removeAttribute("aria-busy");
  chipsRead = true;
  const probe = await swapRestored();
  expect(probe?.held).toBe("");
  release();
});

test("a plain reload (no hand-off) is not held", async () => {
  const next = page(`<main>rows</main>`);
  startSwapRestore(next.document);
  expect(next.document.documentElement.hasAttribute(SWAP_RESTORING_ATTRIBUTE)).toBe(false);
  expect(await swapRestored()).toBeNull();
});

test("a focused password never enters the serialized hand-off", () => {
  const old = page(`<input id="password" type="password">`);
  const field = old.document.getElementById("password") as HTMLInputElement;
  field.value = "example-password-not-for-storage";
  field.focus();
  field.setSelectionRange(2, 5);
  expect(prepareSwap(old.document)).toBe(true);
  const serialized = old.sessionStorage.getItem(SWAP_HANDOFF_KEY)!;
  expect(serialized).not.toContain(field.value);
  expect(JSON.parse(serialized).caret).toBeNull();
  expect(JSON.parse(serialized).fields).toEqual([]);
});

test.each([
  ["email", "example@example.test"],
  ["number", "42"],
])("a focused %s input restores its value and reveals without a selection API", async (type, value) => {
  const body = `<input id="field" type="${type}">`;
  const old = page(body);
  const field = old.document.getElementById("field") as HTMLInputElement;
  field.value = value;
  field.focus();
  expect(field.selectionStart).toBeNull();
  expect(prepareSwap(old.document)).toBe(true);
  const next = reload(old, body);
  startSwapRestore(next.document);
  const probe = await swapRestored();
  const restored = next.document.getElementById("field") as HTMLInputElement;
  expect(restored.value).toBe(value);
  expect(next.document.activeElement).toBe(restored);
  expect(next.document.documentElement.hasAttribute(SWAP_RESTORING_ATTRIBUTE)).toBe(false);
  expect(probe?.kept_fields).toBe(true);
});

test("a replacement input without selection support still reveals", async () => {
  const old = page(`<input id="field" type="text">`);
  const field = old.document.getElementById("field") as HTMLInputElement;
  field.value = "42";
  field.focus();
  field.setSelectionRange(1, 2);
  expect(prepareSwap(old.document)).toBe(true);
  const next = reload(old, `<input id="field" type="number" value="42">`);
  startSwapRestore(next.document);
  const probe = await swapRestored();
  expect(next.document.documentElement.hasAttribute(SWAP_RESTORING_ATTRIBUTE)).toBe(false);
  expect(next.document.activeElement?.id).toBe("field");
  // The old selection cannot be represented by this field; do not report it as kept.
  expect(probe?.kept_selection).toBe(false);
});
