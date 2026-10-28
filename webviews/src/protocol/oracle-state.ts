// The page half of the refactor oracle's `webviews` facet (plans/cmux-next/chrome-parity/p15-oracle.md
// section 3A; schemas/oracle/snapshot-v1.schema.json `facets.webviews`). The host
// (OracleWebviewsFacet, AppServices) calls `cmux.page.oracle.state` on each loaded page and adds the
// page's kind, tab and pane; the page answers its store summary: route, selection, open panels and the
// SHA-256 of its draft. Private text never leaves the page: a draft goes out only as `sha256:<hex>`.
//
// Developer builds only. The bundle is the same in every channel, so the gate is the host's: a DEV or
// bench app installs a document-start script that sets `globalThis.__cmuxOracleState = true`
// (PageWebView+OracleState.swift). Without it (Release, Nightly, the dev loop) no page registers the op
// and `contributeOracleState` keeps nothing. Chromium gates its test-only page state the same way:
// `window.internals` (third_party/blink/renderer/core/testing/internals.idl) exists only when the
// host runs web tests (content_shell `--run-web-tests`), never in a shipped Chrome.

/** The op the host calls on the page (PageRouter.oracleStateOp). */
export const ORACLE_STATE_OP = "cmux.page.oracle.state";
/**
 * The op the page calls when a reading may have changed (PageRouter.oracleStateChangedOp), so the
 * host's `debug.oracle.wait_for` on the `webviews` facet wakes at the change, never by a poll.
 */
export const ORACLE_STATE_CHANGED_OP = "cmux.page.oracle.changed";
/** The global a developer build's document-start script sets (PageWebView.oracleStateScript). */
export const ORACLE_STATE_ENABLED = "__cmuxOracleState";

/** What one part of a page (its store, a composer) knows. Every field is optional. */
export interface OracleStateReading {
  /** The page's route; when no part names one, the URL fragment without `#`, else `/`. */
  route?: string;
  /** The selected item's stable key (a section, a row), never its text; null for none. */
  selection?: string | null;
  /** Panels open now (dialogs, pickers, drawers), by stable name. */
  panels?: readonly string[];
  /** The raw draft text. Only its SHA-256 is sent. */
  draft?: string | null;
}

/** The page's answer: the schema's page object less `page`, `tab` and `pane`, which the host adds. */
export interface OracleState {
  route: string;
  selection: string | null;
  panels: string[];
  draftSha256: string | null;
}

/** The part of a page client that serves host calls (`PageClient.handle`) and calls the host. */
export interface OracleStateHost {
  handle(op: string, handler: (params: unknown) => unknown): () => void;
  call?(op: string, params: unknown): Promise<unknown>;
}

/** The globals the gate and the default route read. */
export type OracleStateTarget = Record<string, unknown> & { location?: { hash?: string } };

type Reader = () => OracleStateReading;

/** The parts that contribute, in contribution order (a Set keeps it). */
const readers = new Set<Reader>();
/** Tells the host a reading may have changed; set while a host is served. */
let tellHost: (() => void) | null = null;
/** A change note is queued for this task (many changes in one task send one note). */
let changeQueued = false;

/** Whether the host asked this document for its oracle state. */
export function oracleStateEnabled(target: OracleStateTarget = globalThis as unknown as OracleStateTarget): boolean {
  return target[ORACLE_STATE_ENABLED] === true;
}

/**
 * Adds a part's reading to the page's answer; returns the function that takes it out. Keeps nothing
 * when the host did not enable the oracle, so a shipped build holds no reader.
 */
export function contributeOracleState(
  read: Reader,
  target: OracleStateTarget = globalThis as unknown as OracleStateTarget,
): () => void {
  if (!oracleStateEnabled(target)) return () => undefined;
  readers.add(read);
  noteOracleStateChanged();
  return () => {
    if (readers.delete(read)) noteOracleStateChanged();
  };
}

/**
 * Says a part's reading may have changed (its draft, its selection). Changes in one task coalesce
 * to one note to the host; nothing is sent when the oracle is off or no host is served.
 */
export function noteOracleStateChanged(): void {
  if (!tellHost || changeQueued) return;
  changeQueued = true;
  queueMicrotask(() => {
    changeQueued = false;
    tellHost?.();
  });
}

/**
 * Serves `cmux.page.oracle.state` on `host` when the host enabled the oracle; returns the unregister
 * function, or null when the op is not served.
 */
export function serveOracleState(
  host: OracleStateHost,
  target: OracleStateTarget = globalThis as unknown as OracleStateTarget,
): (() => void) | null {
  if (!oracleStateEnabled(target)) return null;
  const unhandle = host.handle(ORACLE_STATE_OP, () => readOracleState(target));
  const tell = host.call ? () => void host.call?.(ORACLE_STATE_CHANGED_OP, {}).catch(() => undefined) : null;
  tellHost = tell;
  return () => {
    unhandle();
    if (tellHost === tell) tellHost = null;
  };
}

/** The page's answer now, from every contribution. */
export async function readOracleState(
  target: OracleStateTarget = globalThis as unknown as OracleStateTarget,
  subtle: SubtleCrypto | undefined = globalThis.crypto?.subtle,
): Promise<OracleState> {
  const merged = mergeOracleReadings(
    [...readers].map((read) => read()),
    routeOfHash(target.location?.hash),
  );
  return {
    route: merged.route,
    selection: merged.selection,
    panels: merged.panels,
    draftSha256: merged.draft === null ? null : await sha256Text(merged.draft, subtle),
  };
}

/**
 * Joins the readings: the last part that names a route or a selection wins; panels are the union,
 * sorted; drafts that hold more than white space are joined in contribution order (NUL between),
 * null when there is none.
 */
export function mergeOracleReadings(
  readings: readonly OracleStateReading[],
  fallbackRoute: string,
): { route: string; selection: string | null; panels: string[]; draft: string | null } {
  let route = fallbackRoute;
  let selection: string | null = null;
  const panels = new Set<string>();
  const drafts: string[] = [];
  for (const reading of readings) {
    if (reading.route !== undefined) route = reading.route;
    if (reading.selection !== undefined) selection = reading.selection;
    for (const panel of reading.panels ?? []) panels.add(panel);
    if (reading.draft?.trim()) drafts.push(reading.draft);
  }
  return {
    route,
    selection,
    panels: [...panels].sort(),
    draft: drafts.length ? drafts.join("\u0000") : null,
  };
}

/** `#/settings/theme` is `/settings/theme`; no fragment is `/`. */
export function routeOfHash(hash: string | undefined): string {
  return hash?.replace(/^#/, "") || "/";
}

/** `sha256:<64 lowercase hex>` of the UTF-8 text. Throws `cmux.oracle.no_digest` without WebCrypto. */
export async function sha256Text(text: string, subtle: SubtleCrypto | undefined): Promise<string> {
  if (!subtle)
    throw Object.assign(new Error("this page has no SHA-256 (crypto.subtle)"), { code: "cmux.oracle.no_digest" });
  const digest = new Uint8Array(await subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return `sha256:${Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}
