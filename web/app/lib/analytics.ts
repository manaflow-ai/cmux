"use client";

import posthog from "posthog-js";

export type AnalyticsValue =
  | string
  | number
  | boolean
  | null
  | readonly AnalyticsValue[]
  | { readonly [key: string]: AnalyticsValue };

export type AnalyticsProperties = Record<string, AnalyticsValue>;

const FALLBACK_DISTINCT_ID_KEY = "cmux.analytics.distinct_id";
let memoryFallbackDistinctId: string | null = null;

export async function captureAnalyticsEvent(
  event: string,
  properties: AnalyticsProperties = {},
  options: { readonly distinctId?: string; readonly keepalive?: boolean } = {},
): Promise<boolean> {
  try {
    const response = await fetch("/api/analytics/browser-events", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      keepalive: options.keepalive ?? true,
      body: JSON.stringify({
        event,
        distinctId: options.distinctId ?? getAnalyticsDistinctId(),
        properties: {
          ...browserProperties(),
          ...properties,
        },
        timestamp: new Date().toISOString(),
      }),
    });
    return response.ok;
  } catch {
    return false;
  }
}

export function captureAnalyticsClick(
  event: string,
  properties: AnalyticsProperties = {},
): void {
  void captureAnalyticsEvent(event, properties, { keepalive: true });
}

export function getAnalyticsDistinctId(): string {
  try {
    const distinctId = posthog.get_distinct_id();
    if (typeof distinctId === "string" && distinctId.trim()) return distinctId;
  } catch {
  }
  return getFallbackDistinctId();
}

function browserProperties(): AnalyticsProperties {
  if (typeof window === "undefined") return {};
  return {
    $current_url: window.location.href,
    $host: window.location.host,
    $pathname: window.location.pathname,
    $lib: "cmux-web",
  };
}

function getFallbackDistinctId(): string {
  const storage = browserStorage();
  const stored = readStoredDistinctId(storage);
  if (stored) {
    memoryFallbackDistinctId = stored;
    return stored;
  }

  if (memoryFallbackDistinctId) {
    writeStoredDistinctId(storage, memoryFallbackDistinctId);
    return memoryFallbackDistinctId;
  }

  const generated = createFallbackDistinctId();
  memoryFallbackDistinctId = generated;
  writeStoredDistinctId(storage, generated);
  return generated;
}

function browserStorage(): Storage | null {
  try {
    return typeof globalThis.localStorage === "undefined"
      ? null
      : globalThis.localStorage;
  } catch {
    return null;
  }
}

function readStoredDistinctId(storage: Storage | null): string | null {
  if (!storage) return null;
  try {
    const value = storage.getItem(FALLBACK_DISTINCT_ID_KEY)?.trim();
    return value || null;
  } catch {
    return null;
  }
}

function writeStoredDistinctId(storage: Storage | null, distinctId: string): void {
  if (!storage) return;
  try {
    storage.setItem(FALLBACK_DISTINCT_ID_KEY, distinctId);
  } catch {
    // Storage can be disabled by privacy settings. The in-memory fallback above
    // still keeps one id for this page lifetime.
  }
}

function createFallbackDistinctId(): string {
  const uuid = globalThis.crypto?.randomUUID?.();
  if (uuid) return `cmux-web-${uuid}`;

  const bytes = new Uint8Array(16);
  globalThis.crypto?.getRandomValues?.(bytes);
  if (bytes.some((byte) => byte !== 0)) {
    return `cmux-web-${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
  }

  return `cmux-web-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}
