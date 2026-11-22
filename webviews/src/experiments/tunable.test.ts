import { describe, expect, test } from "bun:test";
import { bezierAt, cssBezier, parseBezier } from "../ui/cubicBezier";
import { readTunes, tunableValue, validateTunables, writeTunes, defineTunable } from "./tunable";

const easing = defineTunable({
  id: "test-easing",
  title: "Test",
  description: "A test curve.",
  kind: "cubic-bezier",
  defaultValue: [0.2, 0.6, 0.1, 1],
});

describe("cubic bezier", () => {
  test("parses the CSS and URL forms and refuses x outside 0...1", () => {
    expect(parseBezier("cubic-bezier(0.42, 0, 0.58, 1)")).toEqual([0.42, 0, 0.58, 1]);
    expect(parseBezier("0.2,0.6,0.1,1")).toEqual([0.2, 0.6, 0.1, 1]);
    expect(parseBezier("1.2,0,0.5,1")).toBeUndefined();
    expect(parseBezier("0,0,1")).toBeUndefined();
    expect(cssBezier([0.2, 0.6, 0.1, 1])).toBe("cubic-bezier(0.2, 0.6, 0.1, 1)");
  });

  test("evaluates like the browser: linear is the identity, ease-in starts slow", () => {
    for (const x of [0, 0.25, 0.5, 0.9, 1]) expect(bezierAt([0, 0, 1, 1], x)).toBeCloseTo(x, 4);
    expect(bezierAt([0.42, 0, 1, 1], 0.25)).toBeLessThan(0.1);
    // CSS ease at 50% of the time is about 80% of the way.
    expect(bezierAt([0.25, 0.1, 0.25, 1], 0.5)).toBeCloseTo(0.8024, 3);
  });
});

describe("tunables", () => {
  test("the host override wins, then storage, then the default; invalid values fall through", () => {
    expect(tunableValue(easing, { overrides: {}, stored: {} })).toEqual([0.2, 0.6, 0.1, 1]);
    expect(tunableValue(easing, { overrides: {}, stored: { "test-easing": "0,0,1,1" } })).toEqual([0, 0, 1, 1]);
    expect(
      tunableValue(easing, { overrides: { "test-easing": "0.5,0,0.5,1" }, stored: { "test-easing": "0,0,1,1" } }),
    ).toEqual([0.5, 0, 0.5, 1]);
    expect(tunableValue(easing, { overrides: { "test-easing": "nope" }, stored: {} })).toEqual([0.2, 0.6, 0.1, 1]);
  });

  test("the tune query keeps valid pairs only, in a stable order", () => {
    const tunes = readTunes("b-curve=0,0,1,1;bad;a-curve=cubic-bezier(0.5, 0, 0.5, 1);c-curve=2,0,0,1");
    expect(tunes).toEqual({ "a-curve": "0.5,0,0.5,1", "b-curve": "0,0,1,1" });
    expect(writeTunes(tunes)).toBe("a-curve=0.5,0,0.5,1;b-curve=0,0,1,1");
  });

  test("validation names a bad id or a repeat", () => {
    expect(validateTunables([easing])).toEqual([]);
    expect(validateTunables([easing, easing])).toEqual(["test-easing: duplicate tunable id"]);
    expect(validateTunables([{ ...easing, id: "Bad Id" }])).toEqual(["Bad Id: the id must be lower kebab case"]);
  });
});
