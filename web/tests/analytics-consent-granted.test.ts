import { expect, mock, test } from "bun:test";
import { fakePostHog, installFakeBrowser } from "./analytics-consent-fake-browser";

installFakeBrowser({ "cmux.analytics-consent": "granted" });
const { client, calls } = fakePostHog();
mock.module("posthog-js", () => ({ default: client }));

test("a visitor who allowed analytics earlier gets PostHog on the next page load", async () => {
  const consent = await import("../app/lib/posthog-client");
  expect(calls).toEqual(["init"]);
  expect(consent.analyticsEnabled()).toBe(true);
});
