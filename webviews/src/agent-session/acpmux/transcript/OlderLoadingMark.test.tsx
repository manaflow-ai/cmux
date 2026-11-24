// Goal idle-wakeups: the older history's mark draws no spinner until the reader can see it, so a chat
// left alone near its latest turns runs no `cmux-spin` loop above the view (cmux#48605 drew one).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { OlderLoadingMark } from "./OlderLoadingMark";

// Puts the observer back as it was: absent stays absent (the leak detector reads an added key).
function restore(saved: typeof IntersectionObserver | undefined, had: boolean) {
  if (had) globalThis.IntersectionObserver = saved!;
  else delete (globalThis as { IntersectionObserver?: unknown }).IntersectionObserver;
}

test("the older history's mark keeps its label and draws no spinner before it is seen", () => {
  const had = "IntersectionObserver" in globalThis;
  const saved = globalThis.IntersectionObserver;
  globalThis.IntersectionObserver = class {} as unknown as typeof IntersectionObserver;
  try {
    const html = renderToStaticMarkup(<OlderLoadingMark label="Loading older messages" style={{ top: 8 }} />);
    expect(html).toContain('class="acpmux-older-loading"');
    expect(html).toContain('aria-label="Loading older messages"');
    expect(html).not.toContain("cv-spinner");
  } finally {
    restore(saved, had);
  }
});

test("with no IntersectionObserver the mark draws its spinner, as before", () => {
  const had = "IntersectionObserver" in globalThis;
  const saved = globalThis.IntersectionObserver;
  delete (globalThis as { IntersectionObserver?: unknown }).IntersectionObserver;
  try {
    expect(renderToStaticMarkup(<OlderLoadingMark label="Loading" style={{}} />)).toContain("cv-spinner");
  } finally {
    restore(saved, had);
  }
});
