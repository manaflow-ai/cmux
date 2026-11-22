// The diff viewer on the shared page host (`cmux-page://cmux.diff/`, plans/cmux-next/diff-host.md
// decision c). The page talks to its host only through the cmuxPage bridge (pages/shared/pageClient):
//   - `cmux.diff.config` answers the viewer config the classic host embedded as
//     `<script id="cmux-diff-viewer-config">`, plus `ops`, the optional ops the host serves;
//   - `cmux.diff.<method>` carries one sidecar request (`protocolHandshake`, `sessionOpen`, ...):
//     params are the request's params, the answer is its `DiffResult`;
//   - the stream `cmux.diff.events` carries the sidecar's `DiffEvent`s;
//   - `cmux.diff.languages` answers the user language pack, and the stream of the same name
//     sends it again when the folder changes;
//   - `cmux.diff.comments {method, params}` carries the classic `cmuxDiffComments` messages
//     (comments, viewed files, viewer prefs). The page uses it only when `ops` lists it.
// Patches are served by the host at `cmux-page://cmux.diff/__patch/<token>/...`.
import { createPageClient, isPageError, type PageClient } from "../pages/shared/pageClient";
import type { DiffViewerConfig } from "../types";

export const DIFF_PAGE_CONFIG_OP = "cmux.diff.config";
export const DIFF_PAGE_EVENTS = "cmux.diff.events";
export const DIFF_PAGE_LANGUAGES = "cmux.diff.languages";
export const DIFF_PAGE_COMMENTS_OP = "cmux.diff.comments";
/** The path prefix of the patches the page host serves. */
export const DIFF_PAGE_PATCH_PREFIX = "/__patch/";
/** The sidecar protocol the page speaks when the host's config names none. */
export const DIFF_PAGE_PROTOCOL_VERSION = 1;

/** The `cmux.diff` op of a sidecar request method. */
export function diffPageOp(method: string): string {
  return `cmux.diff.${method}`;
}

let client: PageClient | null | undefined;

/**
 * The page host client when the viewer runs on the shared page host, else null. One per page: the
 * client owns the page's receive hook. Built on first use, so the classic viewer never installs it.
 */
export function diffPageClient(): PageClient | null {
  if (client === undefined) client = createPageClient();
  return client;
}

/** Test hook: replaces (or with `undefined`, forgets) the page client. */
export function setDiffPageClientForTesting(next: PageClient | null | undefined): void {
  client = next;
}

/** What `cmux.diff.config` answers: the viewer config and the optional ops the host serves. */
export type DiffPageConfig = DiffViewerConfig & { ops?: string[] };

/**
 * Asks the host for the viewer config. A config without a transport gets the page transport, so a
 * host only fills what it knows.
 */
export async function loadPageDiffConfig(page: PageClient): Promise<DiffPageConfig> {
  return normalizePageDiffConfig(await page.call<unknown>(DIFF_PAGE_CONFIG_OP, {}));
}

/** Checks a config answer (`cmux.diff.config`, `cmux.diff.open`) and fills the page transport. */
export function normalizePageDiffConfig(value: unknown): DiffPageConfig {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("cmux diff page config is not an object");
  }
  const config = value as DiffPageConfig;
  const payload = config.payload && typeof config.payload === "object" ? config.payload : {};
  config.payload = {
    ...payload,
    transport: payload.transport ?? { kind: "page", endpoint: "", protocolVersion: DIFF_PAGE_PROTOCOL_VERSION },
  };
  if (config.ops != null && !Array.isArray(config.ops)) config.ops = [];
  return config;
}

/** True when the host's config lists `op` among the optional ops it serves. */
export function diffPageServes(config: DiffPageConfig, op: string): boolean {
  return Array.isArray(config.ops) && config.ops.includes(op);
}

export type DiffLanguageApply = (pack: unknown) => { reloadRequired?: boolean } | undefined;

/**
 * Loads the user language pack from `cmux.diff.languages` and applies every later pack from the
 * stream of the same name. A host without the op or stream is fine (no user languages). Resolves to
 * the initial pack (undefined when there is none) once the stream is subscribed; `apply` runs only
 * for changes, and `reload` when a change needs a page reload.
 */
export async function startPageDiffLanguages(
  page: PageClient,
  apply: DiffLanguageApply,
  reload: () => void = () => location.reload(),
): Promise<unknown> {
  let initial: unknown;
  try {
    initial = (await page.call<unknown>(DIFF_PAGE_LANGUAGES, {})) ?? undefined;
  } catch (error) {
    if (!isUnknownOp(error)) console.warn("cmux diff languages load failed", error);
  }
  try {
    await page.subscribe<unknown>(DIFF_PAGE_LANGUAGES, (pack) => {
      if (apply(pack)?.reloadRequired) reload();
    });
  } catch (error) {
    if (!isUnknownOp(error)) console.warn("cmux diff languages stream failed", error);
  }
  return initial;
}

function isUnknownOp(error: unknown): boolean {
  return isPageError(error) && error.code === "cmux.protocol.unknown_op";
}

/**
 * The URL of a patch the page host serves. `id` may be relative to the page; it must name the
 * page's own origin under `/__patch/`, so a host answer cannot point the viewer elsewhere.
 */
export function pagePatchURL(id: string, base: string): string {
  let url: URL;
  let origin: URL;
  try {
    origin = new URL(base);
    url = new URL(id, origin);
  } catch {
    throw new Error(`cmux diff patch URL is invalid: ${id}`);
  }
  // A custom scheme's `origin` is "null"; compare scheme and host instead.
  const sameOrigin = url.protocol === origin.protocol && url.host === origin.host;
  if (!sameOrigin || !url.pathname.startsWith(DIFF_PAGE_PATCH_PREFIX)) {
    throw new Error(`cmux diff patch URL is outside the page host: ${id}`);
  }
  return url.href;
}
