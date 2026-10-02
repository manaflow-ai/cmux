import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { seedComposer } from "./composerDraft";
import { newSessionParams } from "./direct";

const prompt = () => new JSDOM("<textarea name=prompt></textarea>").window.document.querySelector("textarea")!;

describe("a chat opened from another tab", () => {
  test("starts with the inherited draft, caret at the end", () => {
    const box = prompt();
    expect(seedComposer(box, "https://example.com\n\n")).toBe(true);
    expect(box.value).toBe("https://example.com\n\n");
    expect(box.selectionStart).toBe(box.value.length);
  });

  test("never replaces what the user typed, and ignores empty drafts", () => {
    const box = prompt();
    box.value = "mine";
    expect(seedComposer(box, "draft")).toBe(false);
    expect(box.value).toBe("mine");
    const empty = prompt();
    expect(seedComposer(empty, "  \n")).toBe(false);
    expect(seedComposer(empty, undefined)).toBe(false);
    expect(seedComposer(null, "draft")).toBe(false);
    expect(empty.value).toBe("");
  });

  test("creates its session in the inherited cwd", () => {
    expect(newSessionParams({ cwd: "/work/app" }, "claude")).toEqual({ cwd: "/work/app", mcpServers: [], _meta: { acpmux: { harness: "claude" } } });
    expect(newSessionParams({})).toEqual({ mcpServers: [], _meta: { acpmux: { harness: undefined } } });
  });
});
