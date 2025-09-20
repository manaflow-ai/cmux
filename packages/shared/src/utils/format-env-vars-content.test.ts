import { describe, expect, it } from "vitest";
import { formatEnvVarsContent, type EnvVarEntry } from "./format-env-vars-content.js";

describe("formatEnvVarsContent", () => {
  it("wraps values in quotes and escapes inner quotes", () => {
    const entries: EnvVarEntry[] = [
      { name: "API_KEY", value: "secret" },
      { name: "GREETING", value: 'Hello, "World"!' },
    ];

    const result = formatEnvVarsContent(entries);

    expect(result).toBe('API_KEY="secret"\nGREETING="Hello, \\"World\\"!"');
  });

  it("preserves multiline values", () => {
    const entries: EnvVarEntry[] = [
      {
        name: "PRIVATE_KEY",
        value: '-----BEGIN KEY-----\nline-1\nline-2==\n-----END KEY-----',
      },
      { name: "NEXT", value: "after" },
    ];

    const result = formatEnvVarsContent(entries);

    expect(result).toBe(`PRIVATE_KEY="-----BEGIN KEY-----
line-1
line-2==
-----END KEY-----"
NEXT="after"`);
  });

  it("normalizes carriage returns and skips blank names", () => {
    const entries: EnvVarEntry[] = [
      { name: "", value: "ignored" },
      { name: "WINDOWS", value: "line1\r\nline2" },
    ];

    const result = formatEnvVarsContent(entries);

    expect(result).toBe('WINDOWS="line1\nline2"');
  });
});
