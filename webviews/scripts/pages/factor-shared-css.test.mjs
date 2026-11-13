import { describe, expect, test } from "bun:test";
import { factorSharedCss } from "./factor-shared-css.mjs";

describe("factorSharedCss", () => {
  test("keeps nested at-rules intact", () => {
    const styles = [
      ".shared{color:red}@media (width > 1px){.shared{display:block}}.one{color:blue}",
      ".shared{color:red}@media (width > 1px){.shared{display:block}}.two{color:green}",
    ];
    const { shared, remainders } = factorSharedCss(styles);
    expect(shared).toBe(".shared{color:red}@media (width > 1px){.shared{display:block}}");
    expect(remainders).toEqual([".one{color:blue}", ".two{color:green}"]);
    expect(remainders.map((tail) => shared + tail)).toEqual(styles);
  });
});
