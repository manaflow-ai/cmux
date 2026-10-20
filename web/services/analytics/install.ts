import { randomUUID } from "node:crypto";
import { after } from "next/server";

import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "./iosEventPolicy";

export type InstallProduct = "tui" | "coderouter";
export type InstallMethod = "curl" | "powershell" | "npm" | "uv";
export type InstallEventName =
  | "website_install_command_copied"
  | "website_install_script_requested"
  | "website_install_succeeded";

type InstallCapture = {
  readonly event: InstallEventName;
  readonly product: InstallProduct;
  readonly method: InstallMethod;
  readonly platform?: string;
  readonly version?: string;
};

export function captureInstallEvent(input: InstallCapture): void {
  if (
    process.env.VERCEL_ENV !== "production" &&
    process.env.INSTALL_ANALYTICS_FORCE !== "1"
  ) return;
  const properties: Record<string, string | number | boolean> = {
    product: input.product,
    method: input.method,
    schema_version: 1,
    $insert_id: randomUUID(),
    // Requests are forwarded by Vercel, but explicitly disable GeoIP anyway
    // and avoid creating persistent PostHog person profiles for installers.
    $geoip_disable: true,
    $process_person_profile: false,
  };
  if (safeLabel(input.platform)) properties.platform = input.platform!;
  if (safeVersion(input.version)) properties.version = input.version!;
  const body = JSON.stringify({
    api_key: POSTHOG_PROJECT_KEY,
    event: input.event,
    distinct_id: `anonymous-install:${randomUUID()}`,
    properties,
    timestamp: new Date().toISOString(),
  });
  const task = fetch(`${POSTHOG_HOST}/capture/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
    signal: AbortSignal.timeout(2_000),
  }).then(() => undefined).catch(() => undefined);
  try {
    after(task);
  } catch {
    void task;
  }
}

export function validInstallEventBody(value: unknown): {
  event: "website_install_command_copied" | "website_install_succeeded";
  product: InstallProduct;
  method: InstallMethod;
  platform?: string;
  version?: string;
} | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  if (body.product !== "tui" && body.product !== "coderouter") return null;
  if (
    body.method !== "curl" &&
    body.method !== "powershell" &&
    body.method !== "npm" &&
    body.method !== "uv"
  ) return null;
  if (
    body.event !== undefined &&
    body.event !== "command_copied" &&
    body.event !== "succeeded"
  ) return null;
  if (body.platform !== undefined && !safeLabel(body.platform)) return null;
  if (body.version !== undefined && !safeVersion(body.version)) return null;
  return {
    event: body.event === "command_copied"
      ? "website_install_command_copied"
      : "website_install_succeeded",
    product: body.product,
    method: body.method,
    ...(typeof body.platform === "string" ? { platform: body.platform } : {}),
    ...(typeof body.version === "string" ? { version: body.version } : {}),
  };
}

function safeLabel(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(value);
}

function safeVersion(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9.+-]{1,32}$/.test(value);
}
