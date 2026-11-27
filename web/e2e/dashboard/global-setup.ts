import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import type { FullConfig } from "@playwright/test";

/**
 * Signs in once through Stack's password endpoint and stores the session as
 * the cookies the Hexclave SDK reads, so every test starts signed in without
 * driving the hosted sign-in UI.
 */
export default async function globalSetup(config: FullConfig) {
  const projectId = requiredEnv("NEXT_PUBLIC_STACK_PROJECT_ID");
  // Optional: the production project requires no publishable key.
  const publishableKey = process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY?.trim();
  const email = requiredEnv("CMUX_E2E_STACK_EMAIL");
  const password = requiredEnv("CMUX_E2E_STACK_PASSWORD");
  const apiUrl = process.env.NEXT_PUBLIC_STACK_API_URL ?? "https://api.hexclave.com";
  const response = await fetch(`${apiUrl}/api/v1/auth/password/sign-in`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-stack-project-id": projectId,
      "x-stack-access-type": "client",
      ...(publishableKey ? { "x-stack-publishable-client-key": publishableKey } : {}),
    },
    body: JSON.stringify({ email, password }),
  });
  if (!response.ok) throw new Error(`Stack sign-in failed with ${response.status}`);
  const tokens = await response.json() as { access_token: string; refresh_token: string };
  const baseURL = new URL(config.projects[0]?.use.baseURL ?? "http://localhost:4389");
  const cookie = (name: string, value: string) => ({
    name,
    value: encodeURIComponent(value),
    domain: baseURL.hostname,
    path: "/",
    expires: Math.floor(Date.now() / 1000) + 3600,
    httpOnly: false,
    secure: baseURL.protocol === "https:",
    sameSite: "Lax" as const,
  });
  const state = {
    cookies: [
      cookie(
        `hexclave-refresh-${projectId}--default`,
        JSON.stringify({ refresh_token: tokens.refresh_token, updated_at_millis: Date.now() }),
      ),
      cookie("hexclave-access", JSON.stringify([tokens.refresh_token, tokens.access_token])),
    ],
    origins: [],
  };
  const file = path.resolve("e2e/dashboard/.auth/state.json");
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, JSON.stringify(state));
}

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required for dashboard e2e`);
  return value;
}
