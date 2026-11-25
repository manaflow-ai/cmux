// Fresh install, default settings: the web UI sends no analytics. The webviews ship no analytics or
// crash SDK (posthog-js, Sentry, OpenTelemetry exporters, Segment, Mixpanel, Amplitude) and make no
// call to an analytics or usage-upload endpoint. A telemetry client added later must come with an
// opt-in setting read before it initializes, and this list updated with it (docs/privacy.md).
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const SDKS = [
  "posthog-js",
  "posthog-node",
  "@sentry/",
  "@opentelemetry/",
  "@segment/",
  "analytics-node",
  "mixpanel",
  "amplitude-js",
  "@amplitude/",
  "@datadog/browser-rum",
  "logrocket",
  "@vercel/analytics",
];
const ENDPOINTS = [
  /posthog\.com/i,
  /\bsentry\.io\b/i,
  /\/v1\/usage\/(upload|records)/,
  /\/v1\/install-counts/,
  /\bgoogle-analytics\.com\b|\bgoogletagmanager\.com\b/i,
];

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name === "dist" || name === "gallery") continue;
    const file = path.join(dir, name);
    if (statSync(file).isDirectory()) walk(file, out);
    else if (/\.(tsx?|mjs|js)$/.test(name) && !name.endsWith(".test.ts") && !name.endsWith(".test.tsx")) {
      out.push(file);
    }
  }
  return out;
}

describe("a fresh install sends no telemetry from the web UI", () => {
  test("no analytics or crash-reporting SDK is a dependency", () => {
    const pkg = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
    const deps = Object.keys({ ...pkg.dependencies, ...pkg.devDependencies, ...pkg.optionalDependencies });
    const found = deps.filter((dep) => SDKS.some((sdk) => dep === sdk || dep.startsWith(sdk)));
    expect(found).toEqual([]);
  });

  test("no source imports an analytics SDK or calls an analytics endpoint", () => {
    const offenders: string[] = [];
    for (const file of walk(path.join(root, "src"))) {
      const text = readFileSync(file, "utf8");
      const rel = path.relative(root, file);
      for (const sdk of SDKS) {
        if (
          new RegExp(
            `from\\s+["']${sdk.replace(/[/@-]/g, "\\$&")}|require\\(["']${sdk.replace(/[/@-]/g, "\\$&")}`,
          ).test(text)
        ) {
          offenders.push(`${rel} imports ${sdk}`);
        }
      }
      for (const endpoint of ENDPOINTS) {
        if (endpoint.test(text)) offenders.push(`${rel} names ${endpoint}`);
      }
    }
    expect(offenders).toEqual([]);
  });
});
