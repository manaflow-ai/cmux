#!/usr/bin/env bun

export {};

type Sample = {
  readonly durationMs: number;
  readonly status: number;
  readonly serverTiming: Record<string, number>;
};

type BenchmarkResult = {
  readonly name: string;
  readonly url: string;
  readonly samples: number;
  readonly successful: number;
  readonly statusCounts: Record<string, number>;
  readonly latencyMs: Percentiles;
  readonly serverTimingMs: Record<string, Percentiles>;
};

type Percentiles = {
  readonly p50: number;
  readonly p95: number;
  readonly p99: number;
  readonly min: number;
  readonly max: number;
};

const args = parseArgs(process.argv.slice(2));
const origin = args.origin ?? "https://coderouter.dev";
const samples = positiveInteger(args.samples ?? "30", "samples");
const timeoutMs = positiveInteger(args.timeout ?? "15000", "timeout");
const routeToken = args.token ?? process.env.CODEROUTER_ROUTE_TOKEN;
const targets = [
  { name: "landing", path: "/", expected: [200] },
  { name: "cli_config", path: "/api/cli/config", expected: [200] },
  {
    name: "models_unauthenticated",
    path: "/v1/models",
    expected: routeToken ? [200, 503] : [401],
    authorization: routeToken,
  },
];

const output: BenchmarkResult[] = [];
for (const target of targets) {
  const url = new URL(target.path, origin).toString();
  const collected: Sample[] = [];
  // Warm DNS, TLS, CDN, and function artifacts before retaining measurements.
  await requestSample(url, target.authorization, timeoutMs).catch(() => null);
  for (let index = 0; index < samples; index += 1) {
    collected.push(await requestSample(url, target.authorization, timeoutMs));
  }
  const result = summarize(target.name, url, collected);
  output.push(result);
  if (!collected.every((sample) => target.expected.includes(sample.status))) {
    console.error(
      `${target.name}: unexpected status; expected ${target.expected.join("/ ")}`,
    );
    process.exitCode = 1;
  }
}

console.log(JSON.stringify({
  schemaVersion: 1,
  measuredAt: new Date().toISOString(),
  origin,
  network: "client_to_edge",
  results: output,
}, null, 2));

async function requestSample(
  url: string,
  authorization: string | undefined,
  timeoutMs: number,
): Promise<Sample> {
  const started = performance.now();
  const response = await fetch(url, {
    redirect: "manual",
    headers: {
      ...(authorization ? { authorization: `Bearer ${authorization}` } : {}),
      "user-agent": "coderouter-benchmark/1",
    },
    signal: AbortSignal.timeout(timeoutMs),
  });
  // Drain the response so connection reuse and total duration are comparable.
  await response.arrayBuffer();
  return {
    durationMs: round(performance.now() - started),
    status: response.status,
    serverTiming: parseServerTiming(response.headers.get("server-timing")),
  };
}

function summarize(
  name: string,
  url: string,
  samples: readonly Sample[],
): BenchmarkResult {
  const timingNames = new Set(
    samples.flatMap((sample) => Object.keys(sample.serverTiming)),
  );
  return {
    name,
    url,
    samples: samples.length,
    successful: samples.filter((sample) => sample.status < 500).length,
    statusCounts: Object.fromEntries(
      [...new Set(samples.map((sample) => sample.status))]
        .sort()
        .map((status) => [
          String(status),
          samples.filter((sample) => sample.status === status).length,
        ]),
    ),
    latencyMs: percentiles(samples.map((sample) => sample.durationMs)),
    serverTimingMs: Object.fromEntries(
      [...timingNames].sort().map((timing) => [
        timing,
        percentiles(
          samples
            .map((sample) => sample.serverTiming[timing])
            .filter((value): value is number => value !== undefined),
        ),
      ]),
    ),
  };
}

function parseServerTiming(value: string | null): Record<string, number> {
  if (!value) return {};
  const parsed: Record<string, number> = {};
  for (const entry of value.split(",")) {
    const [name, ...parameters] = entry.trim().split(";");
    if (!name) continue;
    const duration = parameters
      .map((parameter) => parameter.trim().match(/^dur=([0-9.]+)$/)?.[1])
      .find(Boolean);
    if (duration) parsed[name] = Number(duration);
  }
  return parsed;
}

function percentiles(values: readonly number[]): Percentiles {
  if (values.length === 0) {
    return { p50: 0, p95: 0, p99: 0, min: 0, max: 0 };
  }
  const sorted = [...values].sort((left, right) => left - right);
  return {
    p50: quantile(sorted, 0.50),
    p95: quantile(sorted, 0.95),
    p99: quantile(sorted, 0.99),
    min: sorted[0]!,
    max: sorted.at(-1)!,
  };
}

function quantile(sorted: readonly number[], fraction: number): number {
  const index = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil(sorted.length * fraction) - 1),
  );
  return round(sorted[index]!);
}

function round(value: number): number {
  return Math.round(value * 100) / 100;
}

function parseArgs(values: readonly string[]): Record<string, string> {
  const parsed: Record<string, string> = {};
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index]!;
    if (!value.startsWith("--")) throw new Error(`Unexpected argument: ${value}`);
    const [inlineKey, inlineValue] = value.slice(2).split("=", 2);
    const next = values[index + 1];
    if (inlineValue !== undefined) {
      parsed[inlineKey!] = inlineValue;
    } else if (next && !next.startsWith("--")) {
      parsed[inlineKey!] = next;
      index += 1;
    } else {
      throw new Error(`Missing value for --${inlineKey}`);
    }
  }
  return parsed;
}

function positiveInteger(value: string, name: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 60_000) {
    throw new Error(`--${name} must be an integer from 1 to 60000`);
  }
  return parsed;
}
