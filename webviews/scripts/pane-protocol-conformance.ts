#!/usr/bin/env bun
// The TS runner of the oracle's pane-protocol suite (tests/oracle/corpus/pane-protocol/, written by
// scripts/cmux-next/oracle/gen_pane_protocol.py). The Rust runner (cmux-pane-protocol's `conformance`
// example) and the Swift runner (PaneProtocolConformanceTests) read the same files, as every Mojo binding
// reads chromium/src mojo/public/interfaces/bindings/tests/data/validation/.
//
//   bun scripts/pane-protocol-conformance.ts [--corpus DIR] [--json FILE]
//
// A case that does not conform fails the run unless _expectations.json lists it as a known TS divergence; a
// listed case that conforms is an unexpected pass, reported without failing (Blink's TestExpectations rule).
// --json writes one record per case: {case, implementation, result, detail}.

import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { decodeBinaryFrame, decodeEnvelope, encodeBinaryFrame, encodeEnvelope } from "../src/protocol/envelope";
import { ByteStream, type ByteStreamHost } from "../src/protocol/stream";

const IMPLEMENTATION = "ts";
const CATEGORIES = ["envelopes", "frames", "tokens", "credit"] as const;

type Category = (typeof CATEGORIES)[number];
type Json = Record<string, unknown>;
/** Null when the case conforms, else what differed. */
type Check = string | null;

interface Plan {
  categories: Record<string, string>;
  skip: Record<string, string>;
  divergences: Record<string, { bug: string; reason: string }>;
}

const webviewsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function parseArgs(argv: string[]): { corpus: string; json: string | null } {
  let corpus = path.join(webviewsRoot, "..", "tests", "oracle", "corpus", "pane-protocol");
  let json: string | null = null;
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index + 1];
    if (argv[index] === "--corpus" && value) corpus = path.resolve(value);
    else if (argv[index] === "--json" && value) json = path.resolve(value);
    else throw new Error(`unknown argument ${JSON.stringify(argv[index])} (use --corpus DIR, --json FILE)`);
    index += 1;
  }
  return { corpus, json };
}

function read(dir: string, name: string): Json {
  return JSON.parse(readFileSync(path.join(dir, name), "utf8")) as Json;
}

function hexBytes(hex: string): Uint8Array {
  return Uint8Array.from(hex.match(/.{2}/g) ?? [], (byte) => Number.parseInt(byte, 16));
}

function toHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}

function failureOf(fn: () => unknown): string | null {
  try {
    fn();
    return null;
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

function envelopeCase(test: Json): Check {
  const text = String(test.text);
  const refusal = failureOf(() => decodeEnvelope(text));
  if (test.verdict === "invalid")
    return refusal === null ? `accepted as ${encodeEnvelope(decodeEnvelope(text))}` : null;
  if (refusal !== null) return `refused: ${refusal}`;
  const encoded = encodeEnvelope(decodeEnvelope(text));
  if (typeof test.encoded === "string" && encoded !== test.encoded) return `encoded ${encoded} != ${test.encoded}`;
  const again = encodeEnvelope(decodeEnvelope(encoded));
  return again === encoded ? null : `${encoded} re-encodes as ${again}`;
}

function frameCase(test: Json): Check {
  const bytes = hexBytes(String(test.hex));
  const refusal = failureOf(() => decodeBinaryFrame(bytes));
  if (test.verdict === "invalid") return refusal === null ? "accepted" : null;
  if (refusal !== null) return `refused: ${refusal}`;
  const frame = decodeBinaryFrame(bytes);
  const expected = test.frame as { stream: number; credit: number; payload_hex: string };
  const got = { stream: frame.stream, credit: frame.credit, payload_hex: toHex(frame.payload) };
  if (JSON.stringify(got) !== JSON.stringify(expected)) {
    return `decoded ${JSON.stringify(got)} != ${JSON.stringify(expected)}`;
  }
  return toHex(encodeBinaryFrame(frame)) === test.hex ? null : "re-encoding differs";
}

/** Records what a ByteStream sends: payload bytes framed and the code of an abort. */
class RecordingHost implements ByteStreamHost {
  sent = 0;
  aborted: string | null = null;
  sendFrame(_stream: number, payload: Uint8Array): void {
    this.sent += payload.byteLength;
  }
  sendCredit(): void {}
  sendEnd(_stream: number, abort?: { code: string; message: string }): void {
    if (abort) this.aborted = abort.code;
  }
  forget(): void {}
}

function creditCase(test: Json): Check {
  const steps = test.steps as Json[];
  const host = new RecordingHost();
  const stream = new ByteStream(host, 1, "conformance");
  if (test.role === "sender") {
    for (const [index, step] of steps.entries()) {
      // The write resolves once its last byte is framed; `sent` is what this checks.
      if (typeof step.write === "number") void stream.write(new Uint8Array(step.write));
      else if (typeof step.credit === "number") stream.receiveCredit(step.credit);
      else stream.receiveData(new Uint8Array(0), Number(step.frame_credit));
      if (host.sent !== step.sent) return `step ${index}: sent ${host.sent} != ${String(step.sent)}`;
    }
    return null;
  }
  if (test.role !== "receiver") return `unknown credit role ${JSON.stringify(test.role)}`;
  stream.grant(Number(test.window));
  for (const [index, step] of steps.entries()) {
    stream.receiveData(new Uint8Array(Number(step.receive)), 0);
    const got = host.aborted ?? "ok";
    if (got !== step.verdict) return `step ${index}: ${got} != ${String(step.verdict)}`;
  }
  return null;
}

const runners: Record<Category, ((test: Json) => Check) | null> = {
  envelopes: envelopeCase,
  frames: (test) => (test.layer === "data_frame" ? frameCase(test) : `no TS framing for layer ${String(test.layer)}`),
  tokens: null,
  credit: creditCase,
};

function main(): number {
  const { corpus, json } = parseArgs(process.argv.slice(2));
  const plan = (read(corpus, "_expectations.json").implementations as Record<string, Plan>)[IMPLEMENTATION];
  const records: Json[] = [];
  const failures: string[] = [];
  const unexpected: string[] = [];
  let passed = 0;
  let expected = 0;
  let skipped = 0;
  for (const category of CATEGORIES) {
    const decision = plan.categories[category] ?? "missing from _expectations.json";
    const run = runners[category];
    if (decision !== "run") {
      console.log(`${category}: not run: ${decision}`);
      continue;
    }
    if (run === null) {
      failures.push(`${category}: _expectations.json says run, but this runner has no ${category} check`);
      continue;
    }
    for (const test of read(corpus, `_${category}.json`).cases as Json[]) {
      const id = String(test.id);
      const record = (result: string, detail: string) =>
        records.push({ case: id, implementation: IMPLEMENTATION, result, detail });
      if (plan.skip[id]) {
        skipped += 1;
        record("Skip", plan.skip[id]);
        continue;
      }
      const detail = run(test);
      const listed = plan.divergences[id];
      if (detail === null && !listed) {
        passed += 1;
        record("Pass", "");
      } else if (detail === null) {
        unexpected.push(`${id}: conforms; remove its divergence (${listed.bug})`);
        record("Pass", "listed as a divergence");
      } else if (listed) {
        expected += 1;
        record("Failure", detail);
      } else {
        failures.push(`${id}: ${detail}`);
        record("Failure", detail);
      }
    }
  }
  for (const line of unexpected) console.log(`UNEXPECTED PASS ${line}`);
  for (const line of failures) console.log(`FAIL ${line}`);
  console.log(
    `pane-protocol conformance (ts): ${passed} passed, ${expected} known divergences, ${skipped} skipped, ` +
      `${unexpected.length} unexpected passes, ${failures.length} failures`,
  );
  if (json) writeFileSync(json, records.map((record) => JSON.stringify(record)).join("\n") + "\n");
  return failures.length === 0 ? 0 : 1;
}

process.exit(main());
