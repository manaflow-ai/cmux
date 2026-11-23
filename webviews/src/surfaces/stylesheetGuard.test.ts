import { describe, expect, test } from "bun:test";
import cases from "../../../schemas/agent-pane/stylesheet-guard.json";
import { guardedStylesheet, stylesheetFetches } from "./stylesheetGuard";

describe("cmux.stylesheetGuard/1", () => {
  test("a stylesheet that loads something by address is refused, with the same reason as Rust", () => {
    for (const { css, why } of cases.refused) expect([css, stylesheetFetches(css)]).toEqual([css, why]);
  });

  test("any other CSS is allowed: arbitrary selectors, data: images, a url() in a comment", () => {
    for (const css of cases.allowed) expect([css, stylesheetFetches(css)]).toEqual([css, undefined]);
  });

  test("a refused sheet keeps the last good one and says why", () => {
    const heard: string[] = [];
    expect(guardedStylesheet("@import 'x.css';", ".kept {}", (why) => heard.push(why))).toBe(".kept {}");
    expect(heard).toEqual(["it has an @import"]);
    expect(guardedStylesheet(".next {}", ".kept {}", (why) => heard.push(why))).toBe(".next {}");
    expect(heard).toHaveLength(1);
  });
});
