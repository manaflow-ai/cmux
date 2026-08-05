#!/usr/bin/env node
// Mints one one-use enrollment token against the broker and prints ONLY the
// token. Signs in internally (tokens never leave this process) with either
// the dedicated iroh-testbed account (CMUX_DEMO_ACCOUNT_FILE, a JSON file
// with {email,password}) or the team dogfood account from
// ~/.secrets/cmuxterm-dev.env.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const BROKER = process.env.CMUX_TUI_IROH_BROKER;
if (!BROKER) {
  console.error("set CMUX_TUI_IROH_BROKER");
  process.exit(1);
}
const STACK_BASE = process.env.CMUX_TUI_IROH_STACK_BASE ?? "https://api.stack-auth.com";
const PROJECT_ID =
  process.env.CMUX_TUI_IROH_STACK_PROJECT ?? "454ecd03-1db2-4050-845e-4ce5b0cd9895";
const PUBLISHABLE_KEY =
  process.env.CMUX_TUI_IROH_STACK_PCK ?? "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g";

function credentials() {
  const accountFile = process.env.CMUX_DEMO_ACCOUNT_FILE;
  if (accountFile) {
    const parsed = JSON.parse(readFileSync(accountFile, "utf8"));
    if (!parsed.email || !parsed.password) {
      throw new Error(`${accountFile} must contain email and password`);
    }
    return { email: parsed.email, password: parsed.password };
  }
  const path = join(homedir(), ".secrets", "cmuxterm-dev.env");
  const env = {};
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const match = line.match(/^(?:export\s+)?([A-Z0-9_]+)=(.*)$/);
    if (match) env[match[1]] = match[2].replace(/^["']|["']$/g, "");
  }
  if (!env.CMUX_DOGFOOD_STACK_EMAIL || !env.CMUX_DOGFOOD_STACK_PASSWORD) {
    throw new Error("missing dogfood credentials; set CMUX_DEMO_ACCOUNT_FILE instead");
  }
  return { email: env.CMUX_DOGFOOD_STACK_EMAIL, password: env.CMUX_DOGFOOD_STACK_PASSWORD };
}

const { email, password } = credentials();
const signIn = await fetch(`${STACK_BASE}/api/v1/auth/password/sign-in`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    "x-stack-project-id": PROJECT_ID,
    "x-stack-publishable-client-key": PUBLISHABLE_KEY,
    "x-stack-access-type": "client",
  },
  body: JSON.stringify({ email, password }),
});
if (!signIn.ok) {
  console.error(`stack sign-in failed: ${signIn.status}`);
  process.exit(1);
}
const session = await signIn.json();
if (!session.access_token || !session.refresh_token) {
  console.error("stack sign-in response missing access_token/refresh_token");
  process.exit(1);
}

const mint = await fetch(`${BROKER}/api/devices/iroh/enrollment-tokens`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    authorization: `Bearer ${session.access_token}`,
    "x-stack-refresh-token": session.refresh_token,
  },
  body: JSON.stringify({}),
});
const body = await mint.json().catch(() => ({}));
if (!mint.ok || !body.token) {
  console.error(`enrollment token mint failed (${mint.status}): ${JSON.stringify(body).slice(0, 200)}`);
  process.exit(1);
}
console.log(body.token);
