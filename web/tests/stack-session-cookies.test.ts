import { describe, expect, test } from "bun:test";
import {
  hasStackRefreshCookie,
  stackRefreshCookies,
} from "../app/lib/stack-session-cookies";

const project = "9790718f-14cd-4f7e-824d-eaf527a82b82";

describe("stack session cookies", () => {
  test("recognizes every refresh cookie name the SDK writes", () => {
    for (const name of [
      `hexclave-refresh-${project}--abc`,
      `__Host-hexclave-refresh-${project}--abc`,
      `stack-refresh-${project}--abc`,
      `__Host-stack-refresh-${project}--abc`,
      `stack-refresh-${project}`,
      "stack-refresh",
    ]) {
      expect(hasStackRefreshCookie([{ name, value: "token" }], project)).toBe(true);
    }
  });

  test("ignores other cookies, empty values, and other projects", () => {
    expect(hasStackRefreshCookie([
      { name: "hexclave-access", value: "x" },
      { name: `hexclave-refresh-${project}--abc`, value: "" },
      { name: "hexclave-refresh-other-project--abc", value: "x" },
      { name: "NEXT_LOCALE", value: "en" },
    ], project)).toBe(false);
  });

  test("orders current cookies before legacy ones", () => {
    const names = stackRefreshCookies([
      { name: "stack-refresh", value: "old" },
      { name: `hexclave-refresh-${project}--abc`, value: "new" },
    ], project).map((cookie) => cookie.name);
    expect(names).toEqual([`hexclave-refresh-${project}--abc`, "stack-refresh"]);
  });
});
