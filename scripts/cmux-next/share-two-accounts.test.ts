import { expect, test } from "bun:test";
import { bounded } from "./cloud-journey.ts";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { measure, measurements, options, pair, publish } from "./share-two-accounts.ts";

test("one output directory and an optional cleanup mode", () => {
  expect(options(["--out", "/tmp/proof"])).toEqual({ out: "/tmp/proof", cleanup: false });
  expect(options(["--cleanup", "--out", "/tmp/proof"]).cleanup).toBe(true);
  for (const args of [[], ["--out"], ["--out", ""], ["--backend", "prod"], ["--out", "x", "--typo"]]) {
    expect(() => options(args)).toThrow("Usage");
  }
});

test("an incomplete guest pair fails even with a complete owner pair", () => {
  const env = { OWNER_STACK_EMAIL: "a", OWNER_STACK_PASSWORD: "owner credential", GUEST_STACK_EMAIL: "b" };
  expect(() => pair("GUEST", env)).toThrow("Missing staging guest");
  expect(pair("OWNER", env).email).toBe("a");
});

test("actions and observations are correlated across both sides, independent of acknowledgement order", async () => {
  const m = measurements();
  let armed: string | undefined;
  let i = 0;
  let waitingForGuest: string | undefined;
  let observingEnd = false;
  const markers = new Set<string>();
  await measure({
    async prompt(text) {
      expect(armed).toBe(text);
      markers.add(text);
      return i * 1000;
    },
    async waitGuest(text) { waitingForGuest = text; return 22_301; },
    async revoke() { expect(observingEnd).toBe(true); return 23_000; },
  }, {
    async waitUpdate(text) { armed = text; i++; return i * 1000 + i; },
    async send(text) { expect(waitingForGuest).toBe(text); return 22_000; },
    async waitCutoff() { observingEnd = true; return 23_999.9; },
  }, m, () => {});
  expect(markers.size).toBe(20);
  expect(m.updates).toEqual(Array.from({ length: 20 }, (_, j) => j + 1));
  expect(m.delivered).toBe(301);
  expect(m.cutoff).toBeCloseTo(999.9, 6);
  expect(m.events).toHaveLength(44);
});

test("a missing guest observation times out without producing a latency or delivery result", async () => {
  const m = measurements();
  const last: string[] = [];
  const unexpected = async () => { throw new Error("unreachable"); };
  await expect(measure({
    prompt: async () => 1, waitGuest: unexpected, revoke: unexpected,
  }, {
    waitUpdate: () => bounded(new Promise<number>(() => {}), 5, "guest update"),
    send: unexpected, waitCutoff: unexpected,
  }, m, name => last.push(name))).rejects.toThrow("guest update: no answer in 5 ms");
  expect(last).toEqual(["owner update 1 of 20"]);
  expect(m.updates).toHaveLength(0);
  expect(m.delivered).toBeNull();
  expect(m.cutoff).toBeNull();
});

test.skipIf(!process.env.SHARE_LATENCY_REPORT)("the compiled reporter writes the same samples and verdict to the artifact and summary", () => {
  const dir = mkdtempSync(join(tmpdir(), "share-report-"));
  const originalSummary = process.env.GITHUB_STEP_SUMMARY;
  process.env.GITHUB_STEP_SUMMARY = join(dir, "actions-summary.md");
  try {
    const m = measurements();
    m.updates = [...Array.from({ length: 19 }, (_, i) => i + 1), 1500];
    m.delivered = 206;
    m.cutoff = 999.96;
    const result = publish(dir, m, []);
    expect(result.status).toBe("passed");
    expect(result.update_ms).toEqual({ n: 20, p50: 11, p95: 19, max: 1500, samples: m.updates });
    expect(result.within_1s).toEqual({ update_p95: true, revoke: true });
    expect(result.guest_typed_delivered).toBe(true);
    expect(result.guest_typed_delivered_ms).toBe(206);
    const raw = readFileSync(join(dir, "share-two-accounts.json"), "utf8").trim();
    expect(JSON.parse(raw)).toEqual(result);
    expect(readFileSync(join(dir, "summary.md"), "utf8")).toContain(raw);
    expect(readFileSync(process.env.GITHUB_STEP_SUMMARY, "utf8")).toBe(readFileSync(join(dir, "summary.md"), "utf8"));
    m.cutoff = 1000;
    expect(publish(dir, m, []).within_1s.revoke).toBe(false);
    m.updates.pop();
    const partial = publish(dir, m, ["missing observation"]);
    expect(partial.within_1s.update_p95).toBe(false);
    expect(partial.status).toBe("failed");
  } finally {
    if (originalSummary === undefined) delete process.env.GITHUB_STEP_SUMMARY;
    else process.env.GITHUB_STEP_SUMMARY = originalSummary;
    rmSync(dir, { recursive: true, force: true });
  }
});
