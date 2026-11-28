import { describe, expect, test } from "bun:test";
import { underName } from "./stackEdge";

describe("underName", () => {
  test("a name in its place above the body covers none of it", () => {
    expect(underName(132, 132)).toBe(0);
    expect(underName(100, 132)).toBe(0);
  });
  test("a stuck name covers the body by the px it has slid under", () => {
    expect(underName(132, 40)).toBe(92);
    expect(underName(132.4, 131)).toBe(1);
  });
});
