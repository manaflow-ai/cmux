/**
 * Each deployment's HTTPS proxy origins (VM_HTTPS_PROXY_ORIGINS) hold its platforms' lifelines: the API origin and the
 * carrier relay (cmux-platform PrivateEgress.ts), so a machine whose public internet is off keeps cmux through them.
 * Staging's Worker serves the development and staging platforms; production's, production's.
 */
import { expect, it } from "vitest";
import wranglerText from "../../wrangler.jsonc?raw";
import { parseHttpsProxyOrigins } from "../../src/network-origin.ts";

/** One environment's VM_HTTPS_PROXY_ORIGINS value, read from its line in wrangler.jsonc (the file is JSON with comments). */
const originsOf = (env: "staging" | "production"): ReadonlyArray<string> => {
  const start = wranglerText.indexOf(`"${env}": {`);
  expect(start).toBeGreaterThan(-1);
  const line = /"VM_HTTPS_PROXY_ORIGINS": ("(?:[^"\\]|\\.)*")/u.exec(wranglerText.slice(start));
  expect(line).not.toBeNull();
  const raw: unknown = JSON.parse(line?.[1] ?? "null");
  if (typeof raw !== "string") throw new Error(`${env}: VM_HTTPS_PROXY_ORIGINS is not a string`);
  const listed: unknown = JSON.parse(raw);
  if (!Array.isArray(listed)) throw new Error(`${env}: VM_HTTPS_PROXY_ORIGINS is not a list`);
  // Every listed value is an exact https origin: one that is not would disable the whole list.
  expect(parseHttpsProxyOrigins(raw)).toHaveLength(listed.length);
  return parseHttpsProxyOrigins(raw);
};

it("lets staging's machines keep the development and staging API and carrier relay", () => {
  expect(originsOf("staging")).toEqual(expect.arrayContaining([
    "https://cmux-api-development.debussy.workers.dev",
    "https://cmux-remote-relay-development.debussy.workers.dev",
    "https://cloud-api-staging.cmux.dev",
    "https://cmux-remote-relay-staging.debussy.workers.dev",
  ]));
});

it("lets production's machines keep the production API and carrier relay, and only production's", () => {
  const origins = originsOf("production");
  expect(origins).toEqual(expect.arrayContaining([
    "https://cloud-api.cmux.dev",
    "https://cmux-remote-relay-production.debussy.workers.dev",
  ]));
  expect(origins.filter((o) => /development|staging/u.test(o))).toEqual([]);
});
