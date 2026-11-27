// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import { readHostOverload } from "./overloadNoticeModel";
import { retryParts, retryQuietMs } from "./conversation/thinkingModel";
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

test("a classified outage keeps the line short and names the host in its tooltip", () => {
  const retry = readTurnRetry({
    attempt: 3,
    maxRetries: 10,
    cause: "dns",
    host: "api.anthropic.com",
    retryAt: 100_000,
    line: "unavailable",
    showAfterMs: 10_000,
  });
  expect(retry.cause).toBe("dns");
  expect(retry.line).toBe("unavailable");
  const parts = retryParts(t as never, retry);
  expect(parts.label).toBe("turn.live.retry.unavailable");
  expect(parts.detail).toContain("outage.dns");
  expect(parts.detail).toContain("api.anthropic.com");
  expect(retryQuietMs(retry)).toBe(10_000);
});

test("acpmux decides busy or unavailable; an older one's record is read the same way", () => {
  expect(retryParts(t as never, { attempt: 1, maxRetries: 10, errorStatus: 503 }).label).toBe(
    "turn.live.retry.unavailable",
  );
  expect(retryParts(t as never, { errorStatus: 503, line: "busy" }).label).toBe("capacity.live");
  expect(retryParts(t as never, { errorStatus: 529, line: "unavailable" }).label).toBe("turn.live.retry.unavailable");
  // A busy model says so at once; one out of reach waits the bound, so a quick recovery draws nothing.
  expect(retryQuietMs({ errorStatus: 529 })).toBe(0);
  expect(retryQuietMs({ errorStatus: 502 })).toBe(10_000);
  expect(retryQuietMs({ errorStatus: 502, showAfterMs: 4_000 })).toBe(4_000);
});
