import { describe, expect, it } from "bun:test";
import { parseNeedsYou } from "./NeedsYouSection";

describe("needs you wire", () => {
  it("reads the host's rows and answers", () => {
    const state = parseNeedsYou({
      title: "Needs you",
      more: "2 more",
      look: "bar",
      rows: [
        {
          id: "r1",
          headline: "Allow push?",
          who: "a12",
          urgent: true,
          answers: [
            { id: "decline", title: "Decline", role: "plain" },
            { id: "primary", title: "Confirm", role: "destructive", enabled: false },
            { id: "bad" },
          ],
        },
        { id: "", headline: "no id" },
      ],
    });
    expect(state).toEqual({
      title: "Needs you",
      more: "2 more",
      look: "bar",
      rows: [
        {
          id: "r1",
          headline: "Allow push?",
          who: "a12",
          urgent: true,
          answers: [
            { id: "decline", title: "Decline", role: "plain", enabled: true },
            { id: "primary", title: "Confirm", role: "destructive", enabled: false },
          ],
        },
      ],
    });
  });

  it("shows nothing for no rows, null or an unknown shape", () => {
    expect(parseNeedsYou(null)).toBeUndefined();
    expect(parseNeedsYou({ title: "Needs you", rows: [] })).toBeUndefined();
    expect(parseNeedsYou({ rows: [{ id: "r", headline: "h" }] })).toBeUndefined();
    expect(parseNeedsYou({ title: "T", rows: [{ id: "r", headline: "h" }], look: "odd" })?.look).toBe("rows");
  });
});
