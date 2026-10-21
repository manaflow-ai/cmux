// l10n-allow-file: test fixture reply text, not shipped UI.
// A streaming reply ends at its newest character: no caret or bar after it, while the reveal
// writes or while it waits for more (Leo 2026-10-20: the blinking caret goes).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";

const fresh = [{ id: 1, count: 5, born: 0 }];

test("a streaming reply draws no caret after its text", () => {
  for (const waiting of [false, true]) {
    const html = renderToStaticMarkup(
      <Markdown streaming fresh={fresh} now={100} waiting={waiting}>
        {"Hello there world"}
      </Markdown>,
    );
    expect(html).toContain("world");
    expect(html).not.toContain("cv-caret");
  }
});
