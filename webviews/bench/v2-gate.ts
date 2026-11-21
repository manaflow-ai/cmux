/// <reference types="bun" />
// l10n-allow-file: gate output lines, not shipped UI.

/**
 * The page's v2 gate rows, for the gate script's `page` group (scripts/cmux-next/run-v2-gates.sh):
 *
 *   bun bench/v2-gate.ts FILTER
 *
 * runs every row of PAGE_GATES whose name holds FILTER and appends the v2 gate home's line for each
 * to the file V2_GATE_OUT names (cmux-tui/crates/acpmux/benches/v2/mod.rs reads it):
 *
 *   {"name":"v2.pr06.page_store_apply","small_p95":N,"god_p95":N,"unit":"ns"}
 *
 * with no ratio: the home computes it. Each line is printed to stdout as well. A row that needs a
 * DOM says `needs: "browser"` and runs in a browser; where none can be had it fails by name, the
 * way the script's tui_core_native_ready does for cmux-tui-core's inputs. A store-only row runs here,
 * under bun. The exit is 1 when a picked row failed (its line, if written, the script marks
 * `"gate_failed":true`) or did not run, 2 when FILTER is not a word or picks no row.
 *
 * The registry tests in benches/v2/mod.rs read this table's keys: one entry per row, its key on the
 * line that opens it. A later row (row 6's thin_store_geometry, row 7d's page_heap, or a section of
 * another bench such as v2.frame_paced) adds an entry here and a `page` line to its .gates file.
 */
import { appendFileSync } from "node:fs";
import { STORE_MAX_BYTES, STORE_MAX_ROWS } from "../src/agent-session/acpmux/rows/store";
import { heldUnderCap, measureApply, measureHeld, measureText } from "./page-row-store.bench";

/// The home's line: the same fields as every gate row's.
export type GateLine = { name: string; small_p95: number; god_p95: number; unit: string };
/// A row's line, and why the row failed when its own check did (the line is still written).
export type Measured = { line: GateLine; failure?: string };
export type PageGate = { needs: "bun" | "browser"; run: () => Promise<Measured> };

/// ms from performance.now() to the ns every time row of the home is in.
const ns = (ms: number) => Math.round(ms * 1e6);

// The registry tests (cmux-tui/crates/acpmux/benches/v2/mod.rs, page_gates()) find this table's
// rows by a line pattern: an entry's key opens its own line, indented two spaces, quoted, then
// `: {` (`  "v2.pr06.page_store_apply": {`). Keep every entry in that shape: a key the formatter
// or an edit moves off it is a row the tests no longer see.
export const PAGE_GATES: Record<string, PageGate> = {
  "v2.pr06.page_store_apply": {
    needs: "bun",
    run: async () => {
      const { god, small } = await measureApply();
      return {
        line: { name: "v2.pr06.page_store_apply", small_p95: ns(small.p95), god_p95: ns(god.p95), unit: "ns" },
      };
    },
  },
  "v2.pr06.page_store_text": {
    needs: "bun",
    run: async () => {
      const { big, little } = await measureText();
      return {
        line: { name: "v2.pr06.page_store_text", small_p95: ns(little.p95), god_p95: ns(big.p95), unit: "ns" },
      };
    },
  },
  // Both sides measured: the peak bytes each store held while paging up through its chat. The home
  // bounds the god side by the row's god_max (STORE_MAX_BYTES) and the ratio its done-when derives.
  // Beside the line, every run asserts the fixture filled the store: the small side held exactly
  // its 200 rows, the god side paged and its peak rows reached STORE_MAX_ROWS without passing it.
  "v2.pr06.page_store_held": {
    needs: "bun",
    run: async () => {
      const { god, small } = await measureHeld();
      const line = {
        name: "v2.pr06.page_store_held",
        small_p95: small.peakBytes,
        god_p95: god.peakBytes,
        unit: "bytes",
      };
      const failures = [
        heldUnderCap(god)
          ? ""
          : `the god store held ${god.peakRows} rows and ${god.peakBytes} bytes, over the cap of ${STORE_MAX_ROWS} rows and ${STORE_MAX_BYTES} bytes`,
        small.rows === small.chatRows && small.peakRows === small.chatRows
          ? ""
          : `the small store held ${small.rows} rows (peak ${small.peakRows}), not its chat's ${small.chatRows}`,
        god.pages > 0 ? "" : "the god store never paged",
        god.peakRows === STORE_MAX_ROWS
          ? ""
          : `the god store's peak was ${god.peakRows} rows, not the cap of ${STORE_MAX_ROWS}`,
      ].filter(Boolean);
      return failures.length === 0 ? { line } : { line, failure: failures.join("; ") };
    },
  },
};

/// The rows FILTER picks: every name that holds it, as the cargo runners' filters pick tests.
export function pickRows(filter: string, gates: Record<string, PageGate> = PAGE_GATES): string[] {
  if (!/^[A-Za-z0-9_]+$/.test(filter))
    throw new Error(`v2 gates: the page filter ${JSON.stringify(filter)} is not a word`);
  const names = Object.keys(gates).filter((name) => name.includes(filter));
  if (names.length === 0) throw new Error(`v2 gates: the page filter ${filter} picks no row of bench/v2-gate.ts`);
  return names;
}

/// Why a browser cannot be had here, or null when one launches. Only a row that needs one asks.
async function browserMissing(): Promise<string | null> {
  try {
    const { chromium } = await import("./browsers");
    const browser = await chromium.launch({ headless: true });
    await browser.close();
    return null;
  } catch (error) {
    return error instanceof Error ? error.message.split("\n")[0]! : String(error);
  }
}

export async function runPageGates(
  filter: string,
  out: string,
  gates: Record<string, PageGate> = PAGE_GATES,
): Promise<number> {
  let failed = false;
  let noBrowser: string | null | undefined;
  for (const name of pickRows(filter, gates)) {
    const gate = gates[name]!;
    if (gate.needs === "browser") {
      noBrowser ??= await browserMissing();
      if (noBrowser !== null) {
        console.error(`v2 gates: no browser for ${name}; the page group's DOM rows need one (${noBrowser})`);
        failed = true;
        continue;
      }
    }
    let measured: Measured;
    try {
      measured = await gate.run();
    } catch (error) {
      console.error(`v2 gates: ${name} did not run: ${error instanceof Error ? error.message : String(error)}`);
      failed = true;
      continue;
    }
    const { line, failure } = measured;
    if (line.name !== name) throw new Error(`v2 gates: ${name} wrote the line of ${line.name}`);
    const text = JSON.stringify(line);
    appendFileSync(out, `${text}\n`);
    console.log(text);
    if (failure) {
      console.error(`v2 gates: ${name}: ${failure}`);
      failed = true;
    }
  }
  return failed ? 1 : 0;
}

if (import.meta.main) {
  const filter = process.argv[2] ?? "";
  const out = process.env.V2_GATE_OUT;
  if (!out) {
    console.error("v2 gates: V2_GATE_OUT must name the shared nightly measures file");
    process.exit(2);
  }
  let code: number;
  try {
    code = await runPageGates(filter, out);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    code = 2;
  }
  process.exit(code);
}
