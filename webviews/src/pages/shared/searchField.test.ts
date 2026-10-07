import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { focusSearchField } from "./searchField";

function page(body: string): Document {
  return new JSDOM(`<!doctype html><html><body>${body}</body></html>`).window.document;
}

describe("focusSearchField", () => {
  test("focuses the page's search field and selects its text", () => {
    const doc = page(`<input class="keys-search" value="split" /><button>x</button>`);
    const input = doc.querySelector<HTMLInputElement>(".keys-search")!;
    expect(focusSearchField(doc, ".keys-search")).toBe(true);
    expect(doc.activeElement).toBe(input);
    expect(input.selectionStart).toBe(0);
    expect(input.selectionEnd).toBe("split".length);
  });

  test("a page without the field is left alone", () => {
    expect(focusSearchField(page(`<button>x</button>`), ".keys-search")).toBe(false);
  });
});
