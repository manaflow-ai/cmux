import { describe, expect, it } from "vitest";
import { terminalRendererChoice } from "./terminalRenderer";

describe("terminalRendererChoice", () => {
  it("keeps the default without the parameter", () => {
    expect(terminalRendererChoice("")).toBe("default");
    expect(terminalRendererChoice("?ws=ws://127.0.0.1:7681")).toBe("default");
  });

  it("opts into ghostty-web with ?terminal=ghostty", () => {
    expect(terminalRendererChoice("?terminal=ghostty")).toBe("ghostty");
    expect(terminalRendererChoice("?ws=x&terminal=Ghostty")).toBe("ghostty");
  });

  it("ignores other values", () => {
    expect(terminalRendererChoice("?terminal=xterm")).toBe("default");
  });
});
