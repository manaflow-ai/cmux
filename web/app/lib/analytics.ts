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
    return "anonymous";
  }
  return "anonymous";
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
