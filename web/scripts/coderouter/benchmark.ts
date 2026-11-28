#!/usr/bin/env bun

import { pathToFileURL } from "node:url";

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

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) await main();

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const origin = normalizeOrigin(args.origin ?? "https://coderouter.dev");
  const samples = positiveInteger(args.samples ?? "30", "samples");
  const timeoutMs = positiveInteger(args.timeout ?? "15000", "timeout");
  const routeToken = args.token ??
    (isApprovedTokenOrigin(origin)
      ? process.env.CODEROUTER_ROUTE_TOKEN
      : undefined);
  if (
    process.env.CODEROUTER_ROUTE_TOKEN &&
    !args.token &&
    !isApprovedTokenOrigin(origin)
  ) {
    throw new Error(
      "Refusing to send the environment route token to an unapproved origin.",
    );
  }
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
}

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

export function summarize(
  name: string,
  url: string,
  samples: readonly Sample[],
): BenchmarkResult {
  const statusCounts = new Map<number, number>();
  const timingValues = new Map<string, number[]>();
  const durations: number[] = [];
  let successful = 0;
  for (const sample of samples) {
    durations.push(sample.durationMs);
    if (sample.status < 500) successful += 1;
    statusCounts.set(sample.status, (statusCounts.get(sample.status) ?? 0) + 1);
    for (const [name, value] of Object.entries(sample.serverTiming)) {
      const values = timingValues.get(name) ?? [];
      values.push(value);
      timingValues.set(name, values);
    }
  }
  return {
    name,
    url,
    samples: samples.length,
    successful,
    statusCounts: Object.fromEntries(
      [...statusCounts.entries()]
        .sort(([left], [right]) => left - right)
        .map(([status, count]) => [String(status), count]),
    ),
    latencyMs: percentiles(durations),
    serverTimingMs: Object.fromEntries(
      [...timingValues.entries()].sort(([left], [right]) =>
        left.localeCompare(right)
      ).map(([timing, values]) => [
        timing,
        percentiles(values),
      ]),
    ),
  };
}

export function parseServerTiming(value: string | null): Record<string, number> {
  if (!value) return {};
  const parsed: Record<string, number> = {};
  for (const entry of splitOutsideQuotes(value)) {
    const [name, ...parameters] = entry.trim().split(";");
    if (!name) continue;
    const duration = parameters
      .map((parameter) => parameter.trim().match(/^dur=([0-9.]+)$/)?.[1])
      .find(Boolean);
    if (duration) parsed[name] = Number(duration);
  }
  return parsed;
}

function splitOutsideQuotes(value: string): string[] {
  const entries: string[] = [];
  let current = "";
  let quoted = false;
  let escaped = false;
  for (const character of value) {
    if (escaped) {
      current += character;
      escaped = false;
    } else if (character === "\\" && quoted) {
      current += character;
      escaped = true;
    } else if (character === "\"") {
      current += character;
      quoted = !quoted;
    } else if (character === "," && !quoted) {
      entries.push(current);
      current = "";
    } else {
      current += character;
    }
  }
  entries.push(current);
  return entries;
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

export function parseArgs(values: readonly string[]): Record<string, string> {
  const parsed: Record<string, string> = {};
  const supported = new Set(["origin", "samples", "timeout", "token"]);
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index]!;
    if (!value.startsWith("--")) {
      throw new Error("Unexpected benchmark argument.");
    }
    const [inlineKey, inlineValue] = value.slice(2).split("=", 2);
    if (!inlineKey || !supported.has(inlineKey)) {
      throw new Error("Unsupported benchmark option.");
    }
    if (inlineKey in parsed) throw new Error("Duplicate benchmark option.");
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

export function normalizeOrigin(value: string): string {
  const parsed = new URL(value);
  const loopback = parsed.hostname === "localhost" ||
    parsed.hostname === "127.0.0.1" ||
    parsed.hostname === "::1";
  if (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && loopback)) {
    throw new Error("Benchmark origin must use HTTPS except on loopback.");
  }
  if (
    parsed.username || parsed.password || parsed.search || parsed.hash ||
    parsed.pathname !== "/"
  ) {
    throw new Error(
      "Benchmark origin cannot contain credentials, a path, query, or fragment.",
    );
  }
  return parsed.origin;
}

function isApprovedTokenOrigin(origin: string): boolean {
  return origin === "https://coderouter.dev";
}

function positiveInteger(value: string, name: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 60_000) {
    throw new Error(`--${name} must be an integer from 1 to 60000`);
  }
  return parsed;
}
