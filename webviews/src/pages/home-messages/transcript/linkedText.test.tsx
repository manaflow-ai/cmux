import { describe, expect, it } from "bun:test";
import { isValidElement } from "react";
import { linkedText } from "./TranscriptRows";

const links = { fetchPreview: async () => undefined, onOpen: () => {} };

describe("linkedText", () => {
  it("draws each link as a chip and keeps the sentence's punctuation as text", () => {
    const parts = linkedText("See https://example.com/a, then cmux://workspace/w1.", links);
    expect(parts[0]).toBe("See ");
    expect(isValidElement(parts[1]) && (parts[1].props as { href: string }).href).toBe("https://example.com/a");
    expect(parts[2]).toBe(", then ");
    expect(isValidElement(parts[3]) && (parts[3].props as { href: string }).href).toBe("cmux://workspace/w1");
    expect(parts[4]).toBe(".");
  });

  it("leaves text without links as it is", () => {
    expect(linkedText("no links here", links)).toEqual(["no links here"]);
  });
});
