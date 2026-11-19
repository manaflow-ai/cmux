import { describe, expect, test } from "bun:test";
import { MockCloudProvider } from "./mockProvider";
import { cliTrace, createTrace, sampleTraceList, sampleTraces, spareTrace } from "./startTraceFixtures";
import { followAccount, StartTraceStore } from "./startTraceStore";
import { CloudStore } from "./store";
import { axisTicks, countedSpans, formatDuration, isTraceId, waterfall, type StartSpan } from "./startTraces";
import { CloudOps } from "./ops";
import table from "./generated/strings.json";
import { format, L } from "./strings";

const NOW = 1_800_000_000_000;

describe("start trace waterfall", () => {
  test("the app's start has no click row; the axis starts at the server's receipt", () => {
    const chart = waterfall(createTrace(NOW));
    expect(chart.clicked).toBe(false);
    expect(chart.rows.map((row) => row.hop)).toEqual([
      "api",
      "placement",
      "provider_create",
      "restore",
      "boot",
      "network",
      "agent_auth",
      "first_token",
    ]);
    expect(chart.rows[0]!.offset).toBe(0);
  });

  test("a CLI start that timed its click draws it first", () => {
    const chart = waterfall(cliTrace(NOW));
    expect(chart.clicked).toBe(true);
    expect(chart.rows[0]).toMatchObject({ hop: "click", offset: 0, duration: 180 });
  });

  test("a click posted before the server's receipt never shifts the server's bars", () => {
    const base = createTrace(NOW);
    const clicked = {
      ...base,
      spans: [
        { hop: "click", start_ms: base.started_at - 300, end_ms: base.started_at + 20, source: "cli" },
        ...base.spans,
      ],
    };
    const before = waterfall(base);
    const after = waterfall(clicked);
    for (const hop of ["api", "boot", "first_token"])
      expect(after.rows.find((row) => row.hop === hop)!.offset).toBe(
        before.rows.find((row) => row.hop === hop)!.offset,
      );
    expect(after.rows[0]).toMatchObject({ hop: "click", offset: 0, duration: 320 });
    expect(after.rows[0]!.segments[0]!.length).toBe(20);
  });

  test("network adds the server's prepare and attach to the client's connect, each at its own offset", () => {
    const row = waterfall(createTrace(NOW)).rows.find((one) => one.hop === "network")!;
    expect(row.segments.map((segment) => [segment.offset, segment.length, segment.part])).toEqual([
      [84, 120, "prepare"],
      [8214, 410, "attach"],
      [8624, 690, "connect"],
    ]);
    expect(row.duration).toBe(120 + 410 + 690);
  });

  test("the platform's span wins over a client's for any hop but network", () => {
    const spans: StartSpan[] = [
      { hop: "boot", start_ms: 0, end_ms: 100, source: "app" },
      { hop: "boot", start_ms: 0, end_ms: 80, source: "platform" },
    ];
    expect(countedSpans("boot", spans).map((span) => span.source)).toEqual(["platform"]);
    expect(countedSpans("agent_auth", [{ hop: "agent_auth", start_ms: 0, end_ms: 5, source: "machine" }])).toHaveLength(
      1,
    );
  });

  test("a spare has no restore row value, and a hop past p95 is marked slow", () => {
    const spare = waterfall(spareTrace(NOW), sampleTraceList(NOW).hops);
    expect(spare.rows.find((row) => row.hop === "restore")).toMatchObject({ duration: null, slow: false });
    const cli = waterfall(cliTrace(NOW), sampleTraceList(NOW).hops);
    expect(cli.rows.find((row) => row.hop === "boot")!.slow).toBe(true);
    expect(cli.rows.find((row) => row.hop === "api")!.slow).toBe(false);
  });

  test("too few samples never mark a hop slow", () => {
    const chart = waterfall(cliTrace(NOW), { click: { n: 3, p50_ms: 10, p95_ms: 20 } });
    expect(chart.rows[0]!.slow).toBe(false);
  });

  test("the axis covers the last span and its ticks are round", () => {
    const chart = waterfall(createTrace(NOW));
    expect(chart.span).toBe(createTrace(NOW).total_ms);
    expect(axisTicks(13_224)).toEqual([0, 5000, 10000]);
    expect(axisTicks(0)).toEqual([0]);
  });

  test("durations read as ms, then seconds", () => {
    expect(formatDuration(46, "en")).toBe("46ms");
    expect(formatDuration(2810, "en")).toBe("2.81s");
    expect(formatDuration(null, "en")).toBe("–");
  });

  test("every timings string's placeholders are ones `format` fills", () => {
    const en = (table as Record<string, Record<string, string>>).en!;
    for (const key of Object.values(L).filter((one) => one.startsWith("timings."))) {
      const names = [...(en[key] ?? "").matchAll(/\{([^}]*)\}/g)].map((match) => match[1]!);
      const filled = format(en[key]!, Object.fromEntries(names.map((name) => [name, "X"])));
      expect(filled).not.toContain("{");
    }
  });

  test("only contract trace ids are sent", () => {
    expect(isTraceId("st_create_7Qm2xK4p")).toBe(true);
    expect(isTraceId("short")).toBe(false);
    expect(isTraceId("has space in it")).toBe(false);
  });
});

describe("start trace store", () => {
  test("a build that does not serve start traces leaves the entry hidden", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    const store = new StartTraceStore(provider);
    await store.refresh();
    expect(store.getSnapshot()).toMatchObject({ available: false, loading: false });
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("a DEV or NIGHTLY server's answer lists the day and shows the newest start", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    const traces = sampleTraces(NOW);
    provider.startTraces = { list: sampleTraceList(NOW, traces), traces };
    const store = new StartTraceStore(provider);
    await store.refresh();
    const snap = store.getSnapshot();
    expect(snap.available).toBe(true);
    expect(snap.list?.traces).toHaveLength(4);
    expect(snap.trace?.trace).toBe(traces[0]!.trace);
    expect(provider.calls.map((call) => call.op)).toEqual([CloudOps.startTraceList, CloudOps.startTraceGet]);
    await store.select(traces[2]!.trace);
    expect(store.getSnapshot().trace?.trace).toBe(traces[2]!.trace);
    // A refresh keeps the start the person picked.
    await store.refresh();
    expect(store.getSnapshot().selected).toBe(traces[2]!.trace);
  });

  test("reset (a sign-out or another team) forgets the traces and drops reads still in flight", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    const traces = sampleTraces(NOW);
    provider.startTraces = { list: sampleTraceList(NOW, traces), traces };
    const store = new StartTraceStore(provider);
    await store.refresh();
    expect(store.getSnapshot().trace).toBeDefined();
    const late = store.refresh();
    store.reset();
    await late;
    expect(store.getSnapshot()).toEqual({
      available: null,
      list: undefined,
      selected: undefined,
      trace: undefined,
      loading: false,
      error: undefined,
    });
  });

  test("the page's timings follow its account: a sign-out forgets them, another user reads again", async () => {
    const settle = async () => {
      for (let i = 0; i < 30; i++) await Promise.resolve();
    };
    const provider = new MockCloudProvider({ unsupported: [] });
    const traces = sampleTraces(NOW);
    provider.startTraces = { list: sampleTraceList(NOW, traces), traces };
    const cloud = new CloudStore(provider);
    const timings = new StartTraceStore(provider);
    const stopCloud = cloud.subscribe(() => undefined);
    const stop = followAccount(cloud, timings);
    await settle();
    expect(timings.getSnapshot().trace?.trace).toBe(traces[0]!.trace);

    provider.setSignedIn(false);
    await settle();
    expect(timings.getSnapshot()).toMatchObject({ available: null, list: undefined, trace: undefined });

    // The next account's team has no starts: nothing of the previous one shows.
    provider.startTraces = { list: sampleTraceList(NOW, []), traces: [] };
    provider.setSignedIn(true);
    await settle();
    expect(timings.getSnapshot().available).toBe(true);
    expect(timings.getSnapshot().list?.traces).toEqual([]);
    expect(timings.getSnapshot().trace).toBeUndefined();

    provider.startTraces = { list: sampleTraceList(NOW, traces), traces };
    provider.switchUser("user_2", provider.machines);
    await settle();
    expect(timings.getSnapshot().list?.traces).toHaveLength(traces.length);
    stop();
    stopCloud();
  });

  test("a late start read never lands beside an empty list", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    const traces = sampleTraces(NOW);
    provider.startTraces = { list: sampleTraceList(NOW, traces), traces };
    const store = new StartTraceStore(provider);
    await store.refresh();
    const call = provider.call.bind(provider);
    let release: () => void = () => undefined;
    provider.call = async <R>(op: string, params: unknown): Promise<R> => {
      if (op === CloudOps.startTraceGet) await new Promise<void>((resolve) => (release = resolve));
      return call<R>(op, params);
    };
    const pending = store.select(traces[1]!.trace);
    provider.startTraces = { list: sampleTraceList(NOW, []), traces };
    await store.refresh();
    release();
    await pending;
    expect(store.getSnapshot().list?.traces).toEqual([]);
    expect(store.getSnapshot().trace).toBeUndefined();
  });

  test("a failed read says so and keeps the entry", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    provider.startTraces = { list: sampleTraceList(NOW), traces: sampleTraces(NOW) };
    const store = new StartTraceStore(provider);
    await store.refresh();
    provider.failNext = CloudOps.startTraceList;
    await store.refresh();
    expect(store.getSnapshot()).toMatchObject({ available: true, loading: false });
    expect(store.getSnapshot().error).toBeTruthy();
  });
});
