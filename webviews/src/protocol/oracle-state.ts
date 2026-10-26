// The page side of the oracle's `webviews` facet (plans/cmux-next/chrome-parity/p15-oracle.md, 3A;
// task p15-oracle-215). The host asks each page for a summary of its store with the host-to-page
// call `cmux.page.oracle.state`; the page answers {route, selection, panels, draftSha256}.
//
// Private text never leaves the page: a draft is hashed here and only `sha256:<hex>` crosses the
// bridge. A page serves the op only when its document carries `data-oracle="on"`, which the host
// sets only in DEBUG and bench-hook builds, the same builds that register `debug.oracle.*`. A
// Release page has no such handler and answers `cmux.protocol.unknown_op`.

/** The host-to-page op of the facet. */
export const ORACLE_STATE_OP = "cmux.page.oracle.state";

/** `<html data-oracle="on">`: the host's gate (PageWebView+Pooled.swift `installPageScripts`). */
export const ORACLE_GATE_VALUE = "on";

/** One page's answer: the `webviews.pages[]` item of schemas/oracle/snapshot-v1.schema.json without
 * the host's `page`, `tab` and `pane`. */
export interface OracleStateSummary {
  /** The hash route without its query: `#/settings/general?focus=x` is `/settings/general`. */
  route: string;
  /** The selected item's id (never its text), or null. */
  selection: string | null;
  /** Open panels by fixed name, sorted. */
  panels: string[];
  /** `sha256:<hex>` of the drafts, or null when no store has one. */
  draftSha256: string | null;
}

/**
 * What one page store reports. Every value is read from the store's model, never from the DOM.
 * `selection` and `panels` are ids and fixed names; `draft` is private text and is hashed.
 */
export interface OracleStateSource {
  selection?(): string | null;
  panels?(): readonly string[];
  draft?(): string | null;
}

/** The part of the page client that serves host calls (`PageClient.handle`). */
export interface OracleStateHost {
  handle(op: string, handler: (params: unknown) => unknown): () => void;
}

/** SHA-256 of UTF-8 text as lowercase hex; null when the page has no digest. */
export type OracleDigest = (text: string) => Promise<string | null>;

/** Why a page could not answer: it never sends the text in place of a hash. */
export class OracleStateError extends Error {
  readonly code = "cmux.page.oracle.no_digest";
  readonly retryable = false;
  constructor() {
    super("the page has no SHA-256 digest; the draft is not sent");
    this.name = "PageError";
  }
}

const HASH = /^[0-9a-f]{64}$/;

/** WebCrypto's SHA-256, or null where the page has none (a context that is not secure). */
export const webCryptoDigest: OracleDigest = async (text) => {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) return null;
  const bytes = new Uint8Array(await subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
};

/** The route part of a URL fragment. */
export function oracleRoute(hash: string): string {
  const fragment = hash.startsWith("#") ? hash.slice(1) : hash;
  const query = fragment.indexOf("?");
  const route = query === -1 ? fragment : fragment.slice(0, query);
  return route === "" ? "/" : route;
}

/** Whether the host opened the gate on this document. */
export function oracleStateEnabled(root: { dataset?: Record<string, string | undefined> } | null | undefined): boolean {
  return root?.dataset?.oracle === ORACLE_GATE_VALUE;
}

/**
 * The stores of one page document and the summary the host reads. Sources are keyed by a fixed
 * name, and the summary combines them in name order, so it does not depend on mount order.
 */
export class OracleState {
  private readonly sources = new Map<string, OracleStateSource>();

  constructor(
    private readonly hash: () => string,
    private readonly digest: OracleDigest = webCryptoDigest,
  ) {}

  /** Adds (or replaces) the store `name`; returns its removal. */
  provide(name: string, source: OracleStateSource): () => void {
    this.sources.set(name, source);
    return () => this.remove(name, source);
  }

  /** Removes the store `name` when it is still `source`. */
  remove(name: string, source: OracleStateSource): void {
    if (this.sources.get(name) === source) this.sources.delete(name);
  }

  async summary(): Promise<OracleStateSummary> {
    const named = [...this.sources.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    let selection: string | null = null;
    const panels = new Set<string>();
    const drafts: [string, string][] = [];
    for (const [name, source] of named) {
      selection ??= source.selection?.() ?? null;
      for (const panel of source.panels?.() ?? []) panels.add(panel);
      const draft = source.draft?.() ?? null;
      if (draft !== null && draft !== "") drafts.push([name, draft]);
    }
    let draftSha256: string | null = null;
    if (drafts.length > 0) {
      const hex = await this.digest(JSON.stringify(drafts));
      if (hex === null || !HASH.test(hex)) throw new OracleStateError();
      draftSha256 = `sha256:${hex}`;
    }
    return { route: oracleRoute(this.hash()), selection, panels: [...panels].sort(), draftSha256 };
  }

  /** Serves `ORACLE_STATE_OP` on `host`; returns the unregister function. */
  serve(host: OracleStateHost): () => void {
    return host.handle(ORACLE_STATE_OP, () => this.summary());
  }
}

/** The page globals the install reads. */
interface OracleTarget {
  document?: { documentElement?: { dataset?: Record<string, string | undefined> } | null };
  location?: { hash: string };
}

/** This document's state once installed with the gate open (one page per document). */
let installed: OracleState | null = null;
/** Stores that reported before the page client was made (a page that makes it lazily). */
const early = new Map<string, OracleStateSource>();

/**
 * The page's oracle state: serves the op on `host` when the host opened the gate, else does nothing
 * and returns null. Called once by the page client (pages/shared/pageClient.ts).
 */
export function installOracleState(
  host: OracleStateHost,
  target: unknown = globalThis,
  digest: OracleDigest = webCryptoDigest,
): OracleState | null {
  const page = target as OracleTarget;
  if (!oracleStateEnabled(page.document?.documentElement)) return null;
  const state = new OracleState(() => page.location?.hash ?? "", digest);
  for (const [name, source] of early) state.provide(name, source);
  early.clear();
  state.serve(host);
  installed = state;
  return state;
}

/**
 * A page store reports its summary (selection id, panel names, draft) under a fixed `name`.
 * Returns the removal, to call when the store goes away. Before the page client exists the store
 * waits for it; with the gate closed this does nothing.
 */
export function provideOracleState(name: string, source: OracleStateSource, target: unknown = globalThis): () => void {
  if (installed) return installed.provide(name, source);
  if (!oracleStateEnabled((target as OracleTarget).document?.documentElement)) return () => undefined;
  early.set(name, source);
  return () => {
    if (installed) installed.remove(name, source);
    else if (early.get(name) === source) early.delete(name);
  };
}
