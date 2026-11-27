// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import { readHostOverload } from "./overloadNoticeModel";
import { retryParts, formatCountdown } from "./conversation/thinkingModel";
import { readTurnRetry } from "./direct/records";

const t = (key: string, vars?: Record<string, unknown>) => `${key}${vars ? JSON.stringify(vars) : ""}`;

test("overload verdict is read as acpmux sent it", () => {
  expect(
    readHostOverload({ overloaded: true, load1: 290, cores: 15, swapPercent: 95, loadOver: true, swapOver: true }),
  ).toEqual({
    overloaded: true,
    load1: 290,
    cores: 15,
    swapPercent: 95,
    loadOver: true,
    swapOver: true,
  });
  expect(readHostOverload({ cores: 4 })).toBeUndefined();
  expect(readHostOverload(null)).toBeUndefined();
});

test("a classified outage names the host and counts down to acpmux's deadline", () => {
  const retry = readTurnRetry({
    attempt: 3,
    maxRetries: 10,
    cause: "dns",
    host: "api.anthropic.com",
    retryAt: 100_000,
  });
  expect(retry.cause).toBe("dns");
  const parts = retryParts(t as never, retry, 55_000);
  expect(parts.label).toContain("outage.dns");
  expect(parts.label).toContain("api.anthropic.com");
  expect(parts.countdown).toContain("45s");
  expect(retryParts(t as never, retry, 100_001).countdown).toContain("retryingNow");
});

test("a retry with no classification or deadline shows neither", () => {
  const parts = retryParts(t as never, { attempt: 1, maxRetries: 10, errorStatus: 503 }, 5);
  expect(parts.label).toContain("retry.unreachable");
  expect(parts.countdown).toBeUndefined();
  expect(formatCountdown(75)).toBe("1m 15s");
});
