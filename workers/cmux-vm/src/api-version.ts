/**
 * Dated API versions (`Cmux-Api-Version: YYYY-MM-DD`), the cloud side of the
 * promise the cmux-tui socket makes (cmux-tui/spec/api-versioning.md): no
 * breaking change without a new dated version, and every dated version stays
 * served for at least 12 months after the next one ships.
 *
 * A client pins the API it was written against with the request header. The
 * pin resolves to the newest version dated on or before it, so a pin after the
 * newest date gets the newest version. Requests are translated up from the
 * pinned shape and responses down to it, through every change in
 * `API_VERSIONS` dated after the pin; the response names the version served in
 * the same header. A malformed pin, or one older than `BASE_DATE`, is refused
 * with 400 and the update to make.
 *
 * Unpinned requests are served exactly as before: no header, no translation.
 *
 * A change describes how one version differs from the one before it, old to
 * new, on one message (`request:POST /v1/vms`, `response:GET /v1/vms/{vmId}`;
 * a `{name}` segment matches any one path segment). A path is a JSON pointer
 * whose `*` segment walks every item of an array. Ops:
 * - `rename` {path, to}: the field at `path` is now named `to`.
 * - `add` {path, value}: the field at `path` is new; an old client's request
 *   gets `value` filled in, and its responses drop the field.
 * - `remove` {path, value}: the field at `path` is gone; an old client's
 *   request drops it, and its responses get `value` filled in.
 */

import type { Defer, DeferringHandler } from "./after-response.ts";

/** The date of the oldest version this Worker serves (the shape it had when the promise began). */
export const BASE_DATE = "2026-11-24";

export const API_VERSION_HEADER = "cmux-api-version";

export type ApiChange =
  | { readonly message: string; readonly op: "rename"; readonly path: string; readonly to: string }
  | { readonly message: string; readonly op: "add" | "remove"; readonly path: string; readonly value: unknown };

export interface ApiVersion {
  /** `YYYY-MM-DD`, later than `BASE_DATE` and every earlier version. */
  readonly date: string;
  readonly note: string;
  readonly changes: ReadonlyArray<ApiChange>;
}

export interface ApiVersionTable {
  readonly baseDate: string;
  /** Oldest first. */
  readonly versions: ReadonlyArray<ApiVersion>;
}

/** The compat table. Append a version here with every breaking change; empty until the first one. */
export const API_VERSIONS: ApiVersionTable = { baseDate: BASE_DATE, versions: [] };

const DATE = /^(\d{4})-(\d{2})-(\d{2})$/u;

const validDate = (text: string): boolean => {
  const match = DATE.exec(text);
  if (match === null) return false;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const at = new Date(Date.UTC(year, month - 1, day));
  return at.getUTCFullYear() === year && at.getUTCMonth() === month - 1 && at.getUTCDate() === day;
};

/** Throws on a table that breaks its own rules; the tests run it on `API_VERSIONS`. */
export const validateTable = (table: ApiVersionTable): void => {
  if (!validDate(table.baseDate)) throw new Error(`base date ${table.baseDate} is not YYYY-MM-DD`);
  let previous = table.baseDate;
  for (const version of table.versions) {
    if (!validDate(version.date)) throw new Error(`version date ${version.date} is not YYYY-MM-DD`);
    if (version.date <= previous) throw new Error(`version ${version.date} is not after ${previous}`);
    for (const change of version.changes) {
      if (!/^(request|response):[A-Z]+ \/\S*$/u.test(change.message)) throw new Error(`bad message ${change.message}`);
      if (!change.path.startsWith("/") || change.path === "/") throw new Error(`bad path ${change.path}`);
    }
    previous = version.date;
  }
};

export type Pin =
  /** No header: current behaviour. */
  | { readonly kind: "unpinned" }
  /** Served as `date`; `pending` are the versions after it, oldest first. */
  | { readonly kind: "pinned"; readonly date: string; readonly pending: ReadonlyArray<ApiVersion> }
  | { readonly kind: "refused"; readonly response: Response };

const refuse = (requested: string, table: ApiVersionTable, why: string): Pin => {
  const newest = table.versions.at(-1)?.date ?? table.baseDate;
  return {
    kind: "refused",
    response: Response.json(
      {
        _tag: "UnsupportedApiVersion",
        message: `${API_VERSION_HEADER} ${JSON.stringify(requested)} ${why}; pin a date from ${table.baseDate} on (newest ${newest}) or send no header for the current API, and update the client.`,
        requested,
        minApiVersion: table.baseDate,
        apiVersion: newest,
      },
      { status: 400 },
    ),
  };
};

/** Resolved pins per table and header value: clients send a handful of dates, so most requests are one lookup. */
const resolved = new WeakMap<ApiVersionTable, Map<string, Pin & { readonly kind: "pinned" }>>();
const RESOLVED_MAX = 256;

/** Resolves the request's pin. */
export const resolvePin = (header: string | null, table: ApiVersionTable = API_VERSIONS): Pin => {
  if (header === null) return { kind: "unpinned" };
  let cache = resolved.get(table);
  const hit = cache?.get(header);
  if (hit !== undefined) return hit;
  const pin = resolveUncached(header, table);
  if (pin.kind === "pinned") {
    if (cache === undefined) resolved.set(table, (cache = new Map()));
    if (cache.size >= RESOLVED_MAX) cache.clear();
    cache.set(header, pin);
  }
  return pin;
};

const resolveUncached = (header: string, table: ApiVersionTable): Pin => {
  const requested = header.trim();
  if (!validDate(requested)) return refuse(requested, table, "is not a YYYY-MM-DD date");
  if (requested < table.baseDate) return refuse(requested, table, `is older than the oldest version served (${table.baseDate})`);
  let served = table.baseDate;
  let index = 0;
  while (index < table.versions.length && (table.versions[index]?.date ?? "") <= requested) {
    served = table.versions[index]?.date ?? served;
    index += 1;
  }
  return { kind: "pinned", date: served, pending: table.versions.slice(index) };
};

const matches = (template: string, method: string, path: string): boolean => {
  const space = template.indexOf(" ");
  if (template.slice(0, space) !== method) return false;
  const want = template.slice(space + 1).split("/");
  const have = path.split("/");
  if (want.length !== have.length) return false;
  return want.every((segment, i) => (segment.startsWith("{") && segment.endsWith("}")) || segment === have[i]);
};

/** The changes, in the order to apply them, that touch `direction` of this route. */
export const changesFor = (
  pending: ReadonlyArray<ApiVersion>,
  direction: "request" | "response",
  method: string,
  path: string,
): ReadonlyArray<ApiChange> => {
  const prefix = `${direction}:`;
  const picked: Array<ApiChange> = [];
  for (const version of pending) {
    for (const change of version.changes) {
      if (change.message.startsWith(prefix) && matches(change.message.slice(prefix.length), method, path)) picked.push(change);
    }
  }
  // Requests go up (oldest change first); responses come down (newest first).
  return direction === "request" ? picked : picked.reverse();
};

const unescape = (segment: string) => segment.replaceAll("~1", "/").replaceAll("~0", "~");

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** Calls `visit` with every object holding the pointer's last key, and that key. */
const eachParent = (value: unknown, segments: ReadonlyArray<string>, visit: (parent: Record<string, unknown>, key: string) => void): void => {
  const [head, ...rest] = segments;
  if (head === undefined) return;
  if (head === "*") {
    if (Array.isArray(value)) for (const item of value) eachParent(item, rest, visit);
    return;
  }
  if (!isRecord(value)) return;
  if (rest.length === 0) visit(value, head);
  else eachParent(value[head], rest, visit);
};

const pointer = (path: string) => path.split("/").slice(1).map(unescape);

/** Applies one change to `body` in place, forward (old to new) or back (new to old). */
export const applyChange = (body: unknown, change: ApiChange, forward: boolean): void => {
  const segments = pointer(change.path);
  if (change.op === "rename") {
    const [from, to] = forward ? [segments.at(-1) ?? "", change.to] : [change.to, segments.at(-1) ?? ""];
    eachParent(body, segments, (parent) => {
      if (!Object.hasOwn(parent, from)) return;
      parent[to] = parent[from];
      delete parent[from];
    });
    return;
  }
  const fills = (change.op === "add") === forward;
  eachParent(body, segments, (parent, key) => {
    if (fills) {
      if (!Object.hasOwn(parent, key)) parent[key] = structuredClone(change.value);
    } else delete parent[key];
  });
};

const isJson = (headers: Headers) => (headers.get("content-type") ?? "").toLowerCase().includes("application/json");

const translate = async (body: string, changes: ReadonlyArray<ApiChange>, forward: boolean): Promise<string> => {
  const value: unknown = JSON.parse(body);
  for (const change of changes) applyChange(value, change, forward);
  return JSON.stringify(value);
};

/**
 * Serves `handler` with the request's pin: unpinned requests pass straight
 * through; pinned ones are translated both ways and answered with the
 * version served in `Cmux-Api-Version`.
 */
export const withApiVersion =
  (handler: DeferringHandler, table: ApiVersionTable = API_VERSIONS) =>
  async (request: Request, defer?: Defer): Promise<Response> => {
    const pin = resolvePin(request.headers.get(API_VERSION_HEADER), table);
    if (pin.kind === "unpinned") return handler(request, defer);
    if (pin.kind === "refused") return pin.response;
    if (pin.pending.length === 0) return named(await handler(request, defer), pin.date);
    const { pathname } = new URL(request.url);
    let upgraded = request;
    const up = changesFor(pin.pending, "request", request.method, pathname);
    if (up.length > 0 && request.body !== null && isJson(request.headers)) {
      const text = await request.text();
      const body = await translate(text, up, true).catch(() => text);
      upgraded = new Request(request.url, { method: request.method, headers: request.headers, body });
      upgraded.headers.delete("content-length");
    }
    const response = await handler(upgraded, defer);
    const down = changesFor(pin.pending, "response", request.method, pathname);
    if (down.length === 0 || response.body === null || !isJson(response.headers)) return named(response, pin.date);
    const text = await response.text();
    const body = await translate(text, down, false).catch(() => text);
    const served = new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
    served.headers.delete("content-length");
    served.headers.set(API_VERSION_HEADER, pin.date);
    return served;
  };

/** Names the version served; a response with immutable headers (one from fetch) is copied first. */
const named = (response: Response, date: string): Response => {
  try {
    response.headers.set(API_VERSION_HEADER, date);
    return response;
  } catch {
    const copy = new Response(response.body, response);
    copy.headers.set(API_VERSION_HEADER, date);
    return copy;
  }
};
