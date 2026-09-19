import { expect, setSystemTime, test } from "bun:test";
import { Freestyle } from "freestyle";
import { FreestyleResourceStatsReader } from "../services/vms/drivers/freestyleResourceStatsReader";

const reply = () => Response.json({ statusCode: 0, stdout: JSON.stringify({ cpuPercent: 0, memoryUsedMb: 1024, diskUsedMb: 2048 }) });

test("direct probes share a sample and preserve its original time until expiry", async () => {
  let calls = 0;
  const client = new Freestyle({ apiKey: "test-only", fetch: (async () => { calls++; return reply(); }) as typeof fetch });
  const reader = new FreestyleResourceStatsReader(() => client);
  setSystemTime(1_800_000_000_000);
  try {
    const [first, duplicate] = await Promise.all([reader.read("vm-one"), reader.read("vm-one")]);
    expect(calls).toBe(1);
    expect(first).toEqual(duplicate);
    expect(first?.cpuPercent).toBe(0);
    setSystemTime(1_800_000_005_000);
    expect(await reader.read("vm-one")).toEqual(first);
    expect(calls).toBe(1);
    setSystemTime(1_800_000_015_001);
    expect((await reader.read("vm-one"))?.resourceSampledAt).toBe(1_800_000_015_001);
    expect(calls).toBe(2);
  } finally { setSystemTime(); }
});

test("the timestamp is recorded after the sample completes", async () => {
  let complete!: (response: Response) => void;
  let started!: () => void;
  const ready = new Promise<void>(resolve => { started = resolve; });
  const client = new Freestyle({ apiKey: "test-only", fetch: (async () => {
    started();
    return new Promise<Response>(resolve => { complete = resolve; });
  }) as typeof fetch });
  setSystemTime(1_800_000_000_000);
  try {
    const pending = new FreestyleResourceStatsReader(() => client).read("vm-delayed");
    await ready;
    setSystemTime(1_800_000_001_000);
    complete(reply());
    expect((await pending)?.resourceSampledAt).toBe(1_800_000_001_000);
  } finally { setSystemTime(); }
});

test("the deadline aborts a stalled request and caches failure without launching more work", async () => {
  let calls = 0;
  let aborted = false;
  const client = new Freestyle({ apiKey: "test-only", fetch: (async (_input, init) => {
    calls++;
    return new Promise<Response>((_resolve, reject) => {
      init!.signal!.addEventListener("abort", () => { aborted = true; reject(new Error("aborted")); }, { once: true });
    });
  }) as typeof fetch });
  const reader = new FreestyleResourceStatsReader(() => client);
  const results = await Promise.all([reader.read("vm-hung"), reader.read("vm-hung")]);
  expect(results).toEqual([null, null]);
  expect(aborted).toBe(true);
  expect(await reader.read("vm-hung")).toBeNull();
  expect(calls).toBe(1);
}, 15_000);

test.each([202, 409, 503])("HTTP %s is unavailable without background polling or a resume", async status => {
  const calls: string[] = [];
  const client = new Freestyle({ apiKey: "test-only", fetch: (async (url) => {
    calls.push(String(url));
    return Response.json({ requestId: "do-not-poll" }, { status });
  }) as typeof fetch });
  const reader = new FreestyleResourceStatsReader(() => client);
  expect(await reader.read("vm-paused-race")).toBeNull();
  expect(calls).toEqual(["https://api.freestyle.sh/v5/vms/vm-paused-race/exec-await"]);
});
