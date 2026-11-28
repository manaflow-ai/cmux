import { AsyncLocalStorage } from "node:async_hooks";

/**
 * SQLCommenter-style tags appended to every statement the Cloud DB client
 * sends, so PlanetScale Insights can attribute load to a route, a cron, or a
 * script instead of showing one anonymous `postgres.js` application.
 *
 * Keys are bounded on purpose. Never add ids, emails, tokens, or raw URLs:
 * Insights groups by tag value, and unbounded values make every pattern its
 * own bucket. `route` must be the route template (`/api/vm/[id]`), never the
 * concrete path.
 */
export type CloudDbQueryTags = {
  /** app | cron | script | agent */
  readonly source: string;
  /** Route template for request-driven work, for example `/api/devices/iroh/register`. */
  readonly route?: string;
  /** Cron or script name for scheduled and operator work. */
  readonly job?: string;
};

const tagStorage = new AsyncLocalStorage<CloudDbQueryTags>();

export function runWithCloudDbQueryTags<T>(
  tags: CloudDbQueryTags,
  fn: () => T,
): T {
  return tagStorage.run(tags, fn);
}

/**
 * The active tags: an explicit context wins; otherwise a script or cron can
 * name itself through the environment (`CMUX_DB_QUERY_SOURCE`,
 * `CMUX_DB_QUERY_JOB`), which is how the operator backfills and the Vercel
 * cron routes identify themselves without a request wrapper.
 */
export function currentCloudDbQueryTags(): CloudDbQueryTags | undefined {
  const stored = tagStorage.getStore();
  if (stored) return stored;
  const source = process.env.CMUX_DB_QUERY_SOURCE?.trim();
  const job = process.env.CMUX_DB_QUERY_JOB?.trim();
  if (!source && !job) return undefined;
  return { source: source || "script", ...(job ? { job } : {}) };
}

const APPLICATION = "cmux-web";
const MAX_VALUE_LENGTH = 120;

function releaseTag(): string | undefined {
  const sha = process.env.VERCEL_GIT_COMMIT_SHA?.trim();
  if (sha && /^[0-9a-f]{7,40}$/i.test(sha)) return sha.slice(0, 12);
  return undefined;
}

/**
 * Percent-encode a value the way SQLCommenter specifies: the value is
 * URL-encoded, then single quotes and backslashes are escaped so the comment
 * cannot terminate early or carry statement text.
 */
function encodeValue(value: string): string {
  return encodeURIComponent(value.slice(0, MAX_VALUE_LENGTH))
    .replace(/'/g, "%27")
    .replace(/\\/g, "%5C");
}

const SAFE_KEY = /^[a-z_]{1,32}$/;

/** The comment for the current context, or an empty string when nothing applies. */
export function formatCloudDbQueryComment(
  tags: CloudDbQueryTags | undefined = currentCloudDbQueryTags(),
  release: string | undefined = releaseTag(),
): string {
  const pairs: [string, string][] = [["application", APPLICATION]];
  if (release) pairs.push(["release", release]);
  pairs.push(["source", tags?.source ?? "app"]);
  if (tags?.route) pairs.push(["route", tags.route]);
  if (tags?.job) pairs.push(["job", tags.job]);
  const rendered = pairs
    .filter(([key, value]) => SAFE_KEY.test(key) && value.length > 0)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}='${encodeValue(value)}'`)
    .join(",");
  return rendered ? `/*${rendered}*/` : "";
}

/**
 * Append the comment to a statement. SQLCommenter puts the comment last so
 * the statement text, which drivers use for prepared-statement identity,
 * stays at the front. A statement that already carries a SQLCommenter
 * comment is left alone.
 */
export function tagCloudDbQuery(query: string): string {
  if (/\/\*[a-z_]+='/.test(query)) return query;
  const comment = formatCloudDbQueryComment();
  if (!comment) return query;
  const trimmed = query.replace(/\s+$/, "");
  return `${trimmed} ${comment}`;
}
