import { createHash } from "node:crypto";
import { readLimitedBody } from "./limited-body";
import { GITHUB_HOST, isValidKey, listingPath } from "./refs";
import { type Listing, registryBaseUrl } from "./registry";

/**
 * Linking your own repo to its cmux.com page (Leo, 2026-11-17: "ppl should be able to have their
 * own repos be linked up to the cmux.com site or whatever like... think of how i previously had
 * terminal-kit"). The browser talks only to cmux.com's /api/extensions/link routes; they forward to
 * cmux-platform with the person's cmux access token, which never reaches client JS.
 */

/** Where the link and connector routes live: CMUX_PLATFORM_URL, else the registry's own worker. */
export function platformBaseUrl(env: Record<string, string | undefined> = process.env): string {
  const configured = env.CMUX_PLATFORM_URL?.trim();
  return configured ? configured.replace(/\/+$/, "") : registryBaseUrl(env);
}

const hex20 = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 20);

/**
 * The person's own team on cmux-platform: a personal account is a team of one, with ids derived
 * from the Stack identity (cmux-platform src/server/auth/Ids.ts userIdFor and personalTeamIdFor).
 * A personal GitHub connection is linked there, so their own repos are listed there.
 */
export function personalTeamId(stackProjectId: string, stackUserId: string): string {
  return `team_${hex20(`personal:user_${hex20(`stack:${stackProjectId}:${stackUserId}`)}`)}`;
}

/** The page the browser is sent to when it has no session; it comes back to the link page. */
export const LINK_PAGE_PATH = "/extensions/link";

export type LinkSession = { readonly accessToken: string; readonly team: string };

/** A session, or the response to send instead (401 with the sign-in URL, 403, 503). */
export type SessionResult = { readonly ok: true; readonly session: LinkSession } | { readonly ok: false; readonly response: Response };

export type LinkDeps = {
  readonly session: (request: Request) => Promise<SessionResult>;
  readonly fetch: typeof fetch;
  readonly baseUrl: string;
  /** Listings the registry has for a GitHub owner (null: unreachable). */
  readonly authorListings: (owner: string) => Promise<Listing[] | null>;
};

const NO_STORE = { "cache-control": "no-store" } as const;
const PLATFORM_TIMEOUT_MS = 15_000;
const MAX_PLATFORM_BYTES = 2 * 1024 * 1024;

export function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: NO_STORE });
}

export function signInRequired(signInUrl: string): Response {
  return json({ code: "extension.auth_required", message: "Sign in to cmux to link a repo.", signInUrl }, 401);
}

type PlatformAnswer = { readonly status: number; readonly body: unknown };

async function callPlatform(
  deps: LinkDeps,
  session: LinkSession,
  method: "GET" | "POST" | "DELETE",
  path: string,
  query: Record<string, string | undefined>,
  body?: unknown,
): Promise<PlatformAnswer> {
  const search = new URLSearchParams({ team: session.team });
  for (const [key, value] of Object.entries(query)) if (value) search.set(key, value);
  const response = await deps.fetch(`${deps.baseUrl}${path}?${search.toString()}`, {
    method,
    headers: {
      authorization: `Bearer ${session.accessToken}`,
      accept: "application/json",
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: "no-store",
    redirect: "error",
    signal: AbortSignal.timeout(PLATFORM_TIMEOUT_MS),
  });
  const bytes = await readLimitedBody(response, MAX_PLATFORM_BYTES);
  let parsed: unknown = null;
  try {
    parsed = bytes && bytes.byteLength > 0 ? JSON.parse(new TextDecoder().decode(bytes)) : null;
  } catch {
    parsed = null;
  }
  return { status: response.status, body: parsed };
}

function record(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

/** What the browser is told for a refusal: every platform 4xx keeps its status, code and message; anything else is a 503. */
function platformError(answer: PlatformAnswer, signInUrl: string): Response {
  const body = record(answer.body);
  const code = str(body.code) ?? str(body._tag) ?? "extension.unavailable";
  const message = str(body.message) ?? "cmux could not reach the extension registry. Try again in a minute.";
  if (answer.status === 401) return signInRequired(signInUrl);
  if (answer.status >= 400 && answer.status < 500) return json({ code, message }, answer.status);
  return unavailable();
}

function unavailable(): Response {
  return json({ code: "extension.unavailable", message: "cmux could not reach the extension registry. Try again in a minute." }, 503);
}

/** Runs one forwarded call; a network failure or timeout is a 503, never a thrown route. */
async function forward(
  deps: LinkDeps,
  request: Request,
  signInUrl: string,
  run: (session: LinkSession) => Promise<Response>,
): Promise<Response> {
  const resolved = await deps.session(request);
  if (!resolved.ok) return resolved.response;
  try {
    return await run(resolved.session);
  } catch (error) {
    console.error("extensions.link_platform_unavailable", { errorType: error instanceof Error ? error.name : typeof error });
    return unavailable();
  }
}

/** The person's GitHub connection: connected with its login, or not, with the URL that connects it. */
export type GitHubStatus =
  | { readonly connected: true; readonly login: string; readonly avatarUrl?: string }
  | { readonly connected: false; readonly installUrl: string | null };

/** GET /api/extensions/link: whether GitHub is connected, and how to connect it when it is not. */
export async function handleStatus(request: Request, deps: LinkDeps, signInUrl: string): Promise<Response> {
  return forward(deps, request, signInUrl, async (session) => {
    const me = await callPlatform(deps, session, "GET", "/v1/me/github", {});
    if (me.status !== 200) return platformError(me, signInUrl);
    const identity = record(me.body);
    const login = str(identity.login);
    if (identity.connected === true && login) {
      const avatarUrl = str(identity.avatarUrl);
      return json({ connected: true, login, ...(avatarUrl ? { avatarUrl } : {}) } satisfies GitHubStatus);
    }
    const install = await callPlatform(deps, session, "GET", "/v1/connectors/github/install", {});
    const installUrl = httpsOrNull(install.status === 200 ? record(install.body).url : undefined) ?? httpsOrNull(identity.connectUrl);
    // No URL to connect with: say why (expired sign-in, or the registry is down) rather than a dead Connect button.
    if (!installUrl && install.status === 401) return signInRequired(signInUrl);
    if (!installUrl && (install.status !== 200 || install.body === null)) return unavailable();
    return json({ connected: false, installUrl } satisfies GitHubStatus);
  });
}

function httpsOrNull(value: unknown): string | null {
  const raw = str(value);
  if (!raw) return null;
  try {
    return new URL(raw).protocol === "https:" ? raw : null;
  } catch {
    return null;
  }
}

/** One repo the link page shows: public, with its cmux.com page when the registry already lists it. */
export type LinkRepo = {
  readonly fullName: string;
  readonly owner: string;
  readonly name: string;
  /** The listing's cmux.com path, when the registry lists the repo. */
  readonly page?: string;
  /** Listed as a community listing (linked by its owner or found by topic), so it can be unlinked. */
  readonly community?: boolean;
};

export type LinkRepoPage = { readonly repos: LinkRepo[]; readonly cursor: string | null; readonly hiddenPrivate: number };

const REPO_PATTERN = /^(?!\.{1,2}\/)[A-Za-z0-9_.-]{1,100}\/(?!\.{1,2}$)[A-Za-z0-9_.-]{1,100}$/;

function repoRows(body: unknown): { rows: Array<{ fullName: string; owner: string; name: string }>; hiddenPrivate: number } {
  const repos = record(body).repos;
  const rows: Array<{ fullName: string; owner: string; name: string }> = [];
  let hiddenPrivate = 0;
  for (const item of Array.isArray(repos) ? repos : []) {
    const repo = record(item);
    const fullName = str(repo.fullName);
    if (!fullName || !REPO_PATTERN.test(fullName)) continue;
    // A private repo cannot have a public page: the platform refuses it (extension.private).
    if (repo.private !== false) {
      hiddenPrivate += 1;
      continue;
    }
    const [owner, name] = fullName.split("/") as [string, string];
    rows.push({ fullName, owner, name });
  }
  return { rows, hiddenPrivate };
}

/** Each owner's listings once, keyed by lowercased OWNER/REPO, so a page of repos costs one registry read per owner. */
async function listedRepos(deps: LinkDeps, owners: readonly string[]): Promise<Map<string, Listing>> {
  const listed = new Map<string, Listing>();
  const answers = await Promise.all([...new Set(owners.map((owner) => owner.toLowerCase()))].map((owner) => deps.authorListings(owner)));
  for (const listings of answers) {
    for (const listing of listings ?? []) {
      if (listing.host !== GITHUB_HOST) continue;
      const key = `${listing.owner}/${listing.repo}`.toLowerCase();
      // The repo root's listing wins over one in a folder.
      if (!listed.has(key) || listing.path === "") listed.set(key, listing);
    }
  }
  return listed;
}

/** GET /api/extensions/link/repos?query=&cursor=: the person's public repos, with the ones already listed marked. */
export async function handleRepos(request: Request, deps: LinkDeps, signInUrl: string): Promise<Response> {
  const url = new URL(request.url);
  const query = url.searchParams.get("query")?.trim().slice(0, 100) || undefined;
  const cursor = url.searchParams.get("cursor")?.slice(0, 1_000) || undefined;
  return forward(deps, request, signInUrl, async (session) => {
    const answer = await callPlatform(deps, session, "GET", "/v1/connectors/github/repos", { query, cursor });
    if (answer.status !== 200) return platformError(answer, signInUrl);
    const { rows, hiddenPrivate } = repoRows(answer.body);
    const listed = await listedRepos(deps, rows.map((row) => row.owner));
    const repos: LinkRepo[] = rows.map((row) => {
      const listing = listed.get(row.fullName.toLowerCase());
      if (!listing) return row;
      return { ...row, page: listingPath(listing, listing.kind), ...(listing.status === "community" ? { community: true } : {}) };
    });
    const next = str(record(answer.body).cursor) ?? null;
    return json({ repos, cursor: next, hiddenPrivate } satisfies LinkRepoPage);
  });
}

/** What the browser asks to link or unlink: OWNER/REPO and an optional manifest folder. */
export function readLinkTarget(value: { repo?: unknown; path?: unknown }): { repo: string; path: string } | null {
  const repo = str(value.repo);
  if (!repo || !REPO_PATTERN.test(repo)) return null;
  const path = (str(value.path) ?? "").replace(/^\/+|\/+$/g, "");
  const [owner, name] = repo.split("/") as [string, string];
  if (!isValidKey({ host: GITHUB_HOST, owner, repo: name, path })) return null;
  return { repo, path };
}

function invalidTarget(): Response {
  return json({ code: "extension.invalid", message: "Name a GitHub repo as OWNER/REPO." }, 400);
}

/** The link result the page shows: the listing's cmux.com path, or why it is not shown yet. */
export type LinkResult = {
  readonly status: "linked" | "reviewed";
  readonly ref: string;
  readonly kind: string;
  /** cmux.com path of the listing page. */
  readonly page: string;
  readonly problem?: string;
};

/** The listing page as a cmux.com path, from the platform's absolute page URL. */
function sitePath(page: unknown, repo: string): string {
  const raw = str(page);
  if (raw) {
    try {
      const url = new URL(raw, "https://cmux.com");
      if (url.hostname === "cmux.com" || url.hostname.endsWith(".cmux.com")) return `${url.pathname}${url.search}`;
    } catch {
      // Fall through to the page cmux.com builds itself.
    }
  }
  const [owner, name] = repo.split("/") as [string, string];
  return listingPath({ host: GITHUB_HOST, owner, repo: name, path: "" });
}

/** POST /api/extensions/link {repo, path?}: link the repo, answering its page or the problem keeping it hidden. */
export async function handleLink(request: Request, deps: LinkDeps, signInUrl: string): Promise<Response> {
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return invalidTarget();
  }
  const target = readLinkTarget(record(payload));
  if (!target) return invalidTarget();
  return forward(deps, request, signInUrl, async (session) => {
    const answer = await callPlatform(deps, session, "POST", "/v1/extensions/link", {}, {
      repo: target.repo,
      ...(target.path ? { path: target.path } : {}),
    });
    if (answer.status !== 200) return platformError(answer, signInUrl);
    const body = record(answer.body);
    const problem = str(body.problem);
    const result: LinkResult = {
      status: body.status === "reviewed" ? "reviewed" : "linked",
      ref: str(body.ref) ?? `${GITHUB_HOST}/${target.repo}`,
      kind: str(body.kind) ?? "plugin",
      page: sitePath(body.page, target.repo),
      ...(problem ? { problem } : {}),
    };
    return json(result);
  });
}

/** DELETE /api/extensions/link?repo=OWNER/REPO&path=: stop listing a linked repo (a reviewed listing stays). */
export async function handleUnlink(request: Request, deps: LinkDeps, signInUrl: string): Promise<Response> {
  const url = new URL(request.url);
  const target = readLinkTarget({ repo: url.searchParams.get("repo"), path: url.searchParams.get("path") });
  if (!target) return invalidTarget();
  return forward(deps, request, signInUrl, async (session) => {
    const answer = await callPlatform(deps, session, "DELETE", "/v1/extensions/link", {
      repo: target.repo,
      path: target.path || undefined,
    });
    if (answer.status !== 200) return platformError(answer, signInUrl);
    return json({ status: "unlinked" });
  });
}
