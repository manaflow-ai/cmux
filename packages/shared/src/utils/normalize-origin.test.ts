import { describe, expect, it, vi } from "vitest";
import { normalizeOrigin } from "./normalize-origin.js";

describe("normalizeOrigin", () => {
  it("upgrades non-local http origins to https", () => {
    expect(normalizeOrigin("http://cmux.dev")).toBe("https://cmux.dev");
  });

  it("keeps https origins untouched", () => {
    expect(normalizeOrigin("https://cmux.dev")).toBe("https://cmux.dev");
  });

  it("preserves localhost http origins", () => {
    expect(normalizeOrigin("http://localhost:9779")).toBe("http://localhost:9779");
  });

  it("preserves numeric loopback hosts", () => {
    expect(normalizeOrigin("http://127.0.0.1:4000")).toBe("http://127.0.0.1:4000");
  });

  it("returns trimmed origin when parsing fails", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(normalizeOrigin(" not-a-url ")).toBe("not-a-url");
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });
});
