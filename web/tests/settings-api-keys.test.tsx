import { describe, expect, test } from "bun:test";
import {
  API_KEY_EXPIRY_OPTIONS,
  DEFAULT_API_KEY_EXPIRY,
  NEVER_EXPIRES_MS,
  apiKeyExpiresAt,
  apiKeyStatus,
  filterApiKeys,
  isApiKeyExpiryOption,
  isEffectivelyNever,
  sortApiKeys,
  type ApiKeyFacts,
} from "../dashboard-app/screens/settings/lib/api-keys";

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 8, 27);

describe("API key expiry mapping", () => {
  test("offers Hexclave's options with 30 days as the default", () => {
    expect([...API_KEY_EXPIRY_OPTIONS]).toEqual(["1d", "7d", "30d", "90d", "1y", "never"]);
    expect(DEFAULT_API_KEY_EXPIRY).toBe("30d");
  });

  test.each([
    ["1d", DAY],
    ["7d", 7 * DAY],
    ["30d", 30 * DAY],
    ["90d", 90 * DAY],
    ["1y", 365 * DAY],
    ["never", 200 * 365 * DAY],
  ] as const)("%s adds %d ms", (option, offset) => {
    expect(apiKeyExpiresAt(option, NOW).getTime()).toBe(NOW + offset);
  });

  test("never renders as never; real dates do not", () => {
    expect(NEVER_EXPIRES_MS).toBe(200 * 365 * DAY);
    expect(isEffectivelyNever(apiKeyExpiresAt("never", NOW), NOW)).toBe(true);
    expect(isEffectivelyNever(undefined, NOW)).toBe(true);
    expect(isEffectivelyNever(apiKeyExpiresAt("1y", NOW), NOW)).toBe(false);
  });

  test("rejects unknown select values", () => {
    expect(isApiKeyExpiryOption("30d")).toBe(true);
    expect(isApiKeyExpiryOption("2d")).toBe(false);
  });
});

function key(
  description: string,
  createdDay: number,
  reason: "manually-revoked" | "expired" | null = null,
): ApiKeyFacts {
  return {
    description,
    createdAt: new Date(NOW + createdDay * DAY),
    value: { lastFour: description.slice(-4).padStart(4, "0") },
    whyInvalid: () => reason,
  };
}

describe("API key table rules", () => {
  const keys = [
    key("old-valid", 1),
    key("revoked", 5, "manually-revoked"),
    key("new-valid", 3),
    key("expired", 4, "expired"),
  ];

  test("maps whyInvalid to status", () => {
    expect(keys.map(apiKeyStatus)).toEqual(["valid", "revoked", "valid", "expired"]);
  });

  test("sorts valid keys first, newest first", () => {
    expect(sortApiKeys(keys).map((row) => row.description)).toEqual([
      "new-valid",
      "old-valid",
      "revoked",
      "expired",
    ]);
  });

  test("filters by search text and status", () => {
    expect(filterApiKeys(keys, "VALID", new Set()).map((row) => row.description)).toEqual([
      "old-valid",
      "new-valid",
    ]);
    expect(filterApiKeys(keys, "", new Set(["expired", "revoked"])).map((row) => row.description)).toEqual([
      "revoked",
      "expired",
    ]);
    expect(filterApiKeys(keys, "oked", new Set(["valid"]))).toEqual([]);
  });
});
