// The live field's resting draw: the address, or the themed placeholder the static row draws.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { presentation } from "../omnibox/presentation";
import { initialOmnibarState } from "../omnibox/state";
import { OmniboxField } from "./OmniboxField";

const field = () =>
  renderToStaticMarkup(
    <OmniboxField
      inputRef={() => {}}
      presentation={presentation(initialOmnibarState())}
      placeholder="Search or enter address"
    />,
  );

test("a blank tab's resting field draws the themed placeholder over the input", () => {
  const html = field();
  expect(html).toContain('data-resting="true"');
  expect(html).toContain('<span class="bc-address-text bc-placeholder">Search or enter address</span>');
});

test("the input's own placeholder is themed while editing and hidden at rest", () => {
  const css = readFileSync(new URL("../ui/browserChrome.css", import.meta.url), "utf8");
  expect(css).toContain(".bc-omnibox-input::placeholder {\n  color: var(--ds-color-faint);");
  expect(css).toContain(".bc-omnibox-field[data-resting] .bc-omnibox-input::placeholder {\n  color: transparent;");
});
