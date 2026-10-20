// pageFocus.ts (plans/cmux-next/pane-focus-DESIGN.md P1-P3): the page's primary input takes the
// keyboard when the host gives the page focus and nothing in it has focus, also when the input
// mounts after the request; a focused element keeps it.
import { describe, expect, test } from "bun:test";
import { contentFocus, nothingFocused } from "../src/pages/shared/pageFocus";

function fakePage() {
  const body = {} as Element;
  const root = {} as Element;
  const doc = { body, documentElement: root, activeElement: body as Element | null } as unknown as Document & {
    activeElement: Element | null;
  };
  const listeners = new Set<() => void>();
  const win = {
    addEventListener: (_: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_: string, listener: () => void) => listeners.delete(listener),
  } as unknown as Window;
  const target = {
    focused: 0,
    focus() {
      this.focused += 1;
      (doc as { activeElement: Element | null }).activeElement = {} as Element;
    },
  };
  return { doc, win, target, focusWindow: () => listeners.forEach((listener) => listener()), listeners };
}

describe("contentFocus", () => {
  test("a request with nothing focused focuses the mounted input", () => {
    const page = fakePage();
    const focus = contentFocus(page.win, page.doc);
    focus.mount(page.target);
    focus.request();
    expect(page.target.focused).toBe(1);
  });

  test("a request before the input mounts applies once at mount", () => {
    const page = fakePage();
    const focus = contentFocus(page.win, page.doc);
    focus.request();
    expect(page.target.focused).toBe(0);
    focus.mount(page.target);
    expect(page.target.focused).toBe(1);
    focus.mount(null);
    focus.mount(page.target);
    expect(page.target.focused).toBe(1);
  });

  test("a focused element keeps the keyboard, also against a kept request", () => {
    const page = fakePage();
    const focus = contentFocus(page.win, page.doc);
    focus.request();
    (page.doc as { activeElement: Element | null }).activeElement = {} as Element; // the user clicked a field
    focus.mount(page.target);
    focus.request();
    expect(page.target.focused).toBe(0);
  });

  test("the window's focus event is a request; dispose stops listening", () => {
    const page = fakePage();
    const focus = contentFocus(page.win, page.doc);
    focus.mount(page.target);
    page.focusWindow();
    expect(page.target.focused).toBe(1);
    focus.dispose();
    expect(page.listeners.size).toBe(0);
  });

  test("nothingFocused: the body, the root and null count as nothing", () => {
    const page = fakePage();
    expect(nothingFocused(page.doc)).toBe(true);
    (page.doc as { activeElement: Element | null }).activeElement = page.doc.documentElement;
    expect(nothingFocused(page.doc)).toBe(true);
    (page.doc as { activeElement: Element | null }).activeElement = null;
    expect(nothingFocused(page.doc)).toBe(true);
    (page.doc as { activeElement: Element | null }).activeElement = {} as Element;
    expect(nothingFocused(page.doc)).toBe(false);
  });
});
