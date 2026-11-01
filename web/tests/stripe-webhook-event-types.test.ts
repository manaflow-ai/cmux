import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, test } from "bun:test";

import { STRIPE_WEBHOOK_EVENT_TYPES } from "../services/billing/stripeWebhook";

const scriptsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "scripts", "stripe");

function provisionedEventTypes(): string[] {
  const script = readFileSync(join(scriptsDir, "provision-catalog.sh"), "utf8");
  const block = /^EVENTS=\(\n([\s\S]*?)^\)/m.exec(script)?.[1];
  if (!block) throw new Error("provision-catalog.sh has no EVENTS=( ... ) block");
  return [...block.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
}

function devStackEventTypes(): string[] {
  const script = readFileSync(join(scriptsDir, "dev-stack.sh"), "utf8");
  const list = /^events="([^"]+)"$/m.exec(script)?.[1];
  if (!list) throw new Error("dev-stack.sh has no events=\"...\" line");
  return list.split(",");
}

describe("Stripe webhook event subscriptions", () => {
  test("the live endpoint subscribes to exactly the events the webhook handles", () => {
    expect(provisionedEventTypes().toSorted()).toEqual([...STRIPE_WEBHOOK_EVENT_TYPES].toSorted());
  });

  test("the local stripe listen forwards exactly the events the webhook handles", () => {
    expect(devStackEventTypes().toSorted()).toEqual([...STRIPE_WEBHOOK_EVENT_TYPES].toSorted());
  });
});
