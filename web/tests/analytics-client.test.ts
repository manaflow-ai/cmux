import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

let currentPostHogDistinctId: () => string = () => "posthog-distinct-id";
const postHogDistinctId = mock(() => currentPostHogDistinctId());

mock.module("posthog-js", () => ({
  default: {
    get_distinct_id: postHogDistinctId,
  },
}));

const originalLocalStorageDescriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
const { getAnalyticsDistinctId } = await import("../app/lib/analytics");

afterAll(() => {
  if (originalLocalStorageDescriptor) {
    Object.defineProperty(globalThis, "localStorage", originalLocalStorageDescriptor);
  } else {
    delete (globalThis as { localStorage?: Storage }).localStorage;
  }
});

beforeEach(() => {
  postHogDistinctId.mockClear();
  currentPostHogDistinctId = () => "posthog-distinct-id";
  setLocalStorage(new MemoryStorage());
});

describe("analytics client distinct id", () => {
  test("uses the PostHog distinct id when it is available", () => {
    expect(getAnalyticsDistinctId()).toBe("posthog-distinct-id");
  });

  test("persists a generated fallback id when PostHog returns a blank id", () => {
    currentPostHogDistinctId = () => " ";

    const first = getAnalyticsDistinctId();
    const second = getAnalyticsDistinctId();

    expect(first).toStartWith("cmux-web-");
    expect(second).toBe(first);
    expect(globalThis.localStorage.getItem("cmux.analytics.distinct_id")).toBe(first);
  });

  test("uses an existing browser fallback id when PostHog throws", () => {
    globalThis.localStorage.setItem("cmux.analytics.distinct_id", "cmux-web-existing-browser-id");
    currentPostHogDistinctId = () => {
      throw new Error("posthog unavailable");
    };

    expect(getAnalyticsDistinctId()).toBe("cmux-web-existing-browser-id");
  });

  test("keeps a page-lifetime fallback id when browser storage is unavailable", () => {
    currentPostHogDistinctId = () => "";
    setLocalStorage(undefined);

    const first = getAnalyticsDistinctId();
    const second = getAnalyticsDistinctId();

    expect(first).not.toBe("anonymous");
    expect(first).toStartWith("cmux-web-");
    expect(second).toBe(first);
  });
});

function setLocalStorage(storage: Storage | undefined): void {
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: storage,
  });
}

class MemoryStorage implements Storage {
  private readonly values = new Map<string, string>();

  get length(): number {
    return this.values.size;
  }

  clear(): void {
    this.values.clear();
  }

  getItem(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  key(index: number): string | null {
    return Array.from(this.values.keys())[index] ?? null;
  }

  removeItem(key: string): void {
    this.values.delete(key);
  }

  setItem(key: string, value: string): void {
    this.values.set(key, value);
  }
}
