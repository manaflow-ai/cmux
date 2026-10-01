import { projectPermissionsCrud } from "@hexclave/shared/dist/interface/crud/project-permissions";
import { teamPermissionsCrud } from "@hexclave/shared/dist/interface/crud/team-permissions";
import { teamsCrud } from "@hexclave/shared/dist/interface/crud/teams";
import { usersCrud } from "@hexclave/shared/dist/interface/crud/users";
import { array, object, string, type InferType, type ISchema } from "yup";
import { stackApiBaseURL } from "../stackApiBaseURL";
import { validateHexclave } from "./webhookEvents";

/**
 * Hexclave server REST reads used to reconcile the mirror. Every response is
 * validated against the same Hexclave yup schema the backend serializes with,
 * so the types below are inferred from those schemas, not written by hand.
 */
export type HexclaveServerUser = InferType<typeof usersCrud.server.readSchema>;
export type HexclaveServerTeam = InferType<typeof teamsCrud.server.readSchema>;
export type HexclaveTeamPermission = InferType<typeof teamPermissionsCrud.server.readSchema>;
export type HexclaveProjectPermission = InferType<typeof projectPermissionsCrud.server.readSchema>;

export type HexclavePage<T> = { readonly items: readonly T[]; readonly nextCursor: string | null };

export type HexclaveSource = {
  readonly getUser: (userId: string) => Promise<HexclaveServerUser | null>;
  readonly getTeam: (teamId: string) => Promise<HexclaveServerTeam | null>;
  /** Every team the user is a direct member of (Hexclave returns the full list unpaged). */
  readonly listUserTeams: (userId: string) => Promise<readonly HexclaveServerTeam[]>;
  /** Direct (non-recursive) team permissions of the user across all teams. */
  readonly listUserTeamPermissions: (userId: string) => Promise<readonly HexclaveTeamPermission[]>;
  /** Direct (non-recursive) project permissions of the user. */
  readonly listUserProjectPermissions: (userId: string) => Promise<readonly HexclaveProjectPermission[]>;
  readonly listUsersPage: (cursor: string | null, limit: number) => Promise<HexclavePage<HexclaveServerUser>>;
  readonly listTeamsPage: (cursor: string | null, limit: number) => Promise<HexclavePage<HexclaveServerTeam>>;
  /** One page of a team's direct members (all users, anonymous included). */
  readonly listTeamMembersPage: (
    teamId: string,
    cursor: string | null,
    limit: number,
  ) => Promise<HexclavePage<HexclaveServerUser>>;
  /** Every direct team permission in the project, in one unpaged call. */
  readonly listAllTeamPermissions: () => Promise<readonly HexclaveTeamPermission[]>;
  /** Every direct project permission in the project, in one unpaged call. */
  readonly listAllProjectPermissions: () => Promise<readonly HexclaveProjectPermission[]>;
};

/** A Hexclave answer that is not the expected schema, or a non-2xx status. Retryable from the webhook's view. */
export class HexclaveApiError extends Error {
  constructor(
    message: string,
    readonly details: { readonly status?: number; readonly knownError?: string | null; readonly errors?: readonly string[] } = {},
  ) {
    super(message);
    this.name = "HexclaveApiError";
  }
}

export type HexclaveServerApiConfig = {
  readonly projectId: string;
  readonly secretServerKey: string;
  readonly baseURL?: string;
  readonly fetch?: typeof fetch;
  readonly timeoutMs?: number;
  /**
   * Extra attempts after a 429 or 5xx answer. The webhook keeps this small and
   * lets Svix retry the whole delivery; the backfill raises it to ride out
   * Hexclave's rate limit.
   */
  readonly retries?: number;
  /** Bounded backoff between retries; injected so tests do not wait. */
  readonly sleep?: (ms: number) => Promise<void>;
};

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Retry-After seconds when present (capped at 30s), else exponential backoff from 500ms. */
export function hexclaveRetryDelayMs(response: Response, attempt: number): number {
  const retryAfter = Number(response.headers.get("retry-after"));
  if (Number.isFinite(retryAfter) && retryAfter > 0) return Math.min(retryAfter * 1_000, 30_000);
  return Math.min(500 * 2 ** attempt, 30_000);
}

const NOT_FOUND_ERRORS = new Set(["USER_NOT_FOUND", "TEAM_NOT_FOUND"]);

const pagination = object({ next_cursor: string().nullable().defined() }).optional().default(undefined);
const userListSchema = object({ items: array(usersCrud.server.readSchema).defined(), pagination }).defined();
const teamListSchema = object({ items: array(teamsCrud.server.readSchema).defined(), pagination }).defined();
const teamPermissionListSchema = object({ items: array(teamPermissionsCrud.server.readSchema).defined(), pagination }).defined();
const projectPermissionListSchema = object({
  items: array(projectPermissionsCrud.server.readSchema).defined(),
  pagination,
}).defined();

export function createHexclaveServerApi(config: HexclaveServerApiConfig): HexclaveSource {
  const fetchImpl = config.fetch ?? fetch;
  const base = (() => {
    const root = (config.baseURL ?? stackApiBaseURL()).replace(/\/+$/u, "");
    return /\/api\/v1$/u.test(root) ? root : `${root}/api/v1`;
  })();

  const retries = config.retries ?? 1;
  const sleep = config.sleep ?? defaultSleep;

  async function request(path: string, query: Record<string, string | undefined> = {}): Promise<Response> {
    for (let attempt = 0; ; attempt += 1) {
      let response: Response;
      try {
        response = await requestOnce(path, query);
      } catch (error) {
        // A timeout or network failure on an idempotent GET is retried like a 5xx.
        if (attempt >= retries) throw error;
        await sleep(Math.min(500 * 2 ** attempt, 30_000));
        continue;
      }
      if ((response.status !== 429 && response.status < 500) || attempt >= retries) return response;
      await response.body?.cancel();
      await sleep(hexclaveRetryDelayMs(response, attempt));
    }
  }

  function requestOnce(path: string, query: Record<string, string | undefined>): Promise<Response> {
    const url = new URL(`${base}${path}`);
    for (const [key, value] of Object.entries(query)) if (value !== undefined) url.searchParams.set(key, value);
    return fetchImpl(url, {
      method: "GET",
      headers: {
        // Current Hexclave names plus the Stack aliases, as in app/lib/stack.ts.
        "x-hexclave-access-type": "server",
        "x-hexclave-project-id": config.projectId,
        "x-hexclave-secret-server-key": config.secretServerKey,
        "x-stack-access-type": "server",
        "x-stack-project-id": config.projectId,
        "x-stack-secret-server-key": config.secretServerKey,
      },
      signal: AbortSignal.timeout(config.timeoutMs ?? 10_000),
      cache: "no-store",
    });
  }

  async function read<S extends ISchema<unknown>>(
    schema: S,
    path: string,
    query?: Record<string, string | undefined>,
  ): Promise<InferType<S> | null> {
    const response = await request(path, query);
    const knownError = response.headers.get("x-hexclave-known-error") ?? response.headers.get("x-stack-known-error");
    if (response.status === 404 && knownError && NOT_FOUND_ERRORS.has(knownError)) return null;
    if (!response.ok) {
      // No response body in the error: Hexclave can echo account data.
      throw new HexclaveApiError(`Hexclave GET ${path.split("/")[1]} failed`, { status: response.status, knownError });
    }
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      throw new HexclaveApiError(`Hexclave GET ${path.split("/")[1]} returned non-JSON`, { status: response.status });
    }
    const result = await validateHexclave(schema, body);
    if (!result.ok) {
      throw new HexclaveApiError(`Hexclave GET ${path.split("/")[1]} failed schema validation`, { errors: result.errors });
    }
    return result.value;
  }

  async function readList<S extends ISchema<unknown>>(
    schema: S,
    path: string,
    query: Record<string, string | undefined>,
  ): Promise<InferType<S>> {
    const result = await read(schema, path, query);
    if (result === null) throw new HexclaveApiError(`Hexclave GET ${path.split("/")[1]} answered not found`);
    return result;
  }

  return {
    getUser: (userId) => read(usersCrud.server.readSchema, `/users/${encodeURIComponent(userId)}`),
    getTeam: (teamId) => read(teamsCrud.server.readSchema, `/teams/${encodeURIComponent(teamId)}`),
    listUserTeams: async (userId) => (await readList(teamListSchema, "/teams", { user_id: userId })).items,
    listUserTeamPermissions: async (userId) =>
      (await readList(teamPermissionListSchema, "/team-permissions", { user_id: userId, recursive: "false" })).items,
    listUserProjectPermissions: async (userId) =>
      (await readList(projectPermissionListSchema, "/project-permissions", { user_id: userId, recursive: "false" })).items,
    listUsersPage: async (cursor, limit) => {
      const page = await readList(userListSchema, "/users", {
        limit: String(limit),
        cursor: cursor ?? undefined,
        include_anonymous: "true",
      });
      return { items: page.items, nextCursor: page.pagination?.next_cursor ?? null };
    },
    listTeamMembersPage: async (teamId, cursor, limit) => {
      const page = await readList(userListSchema, "/users", {
        team_id: teamId,
        limit: String(limit),
        cursor: cursor ?? undefined,
        include_anonymous: "true",
      });
      return { items: page.items, nextCursor: page.pagination?.next_cursor ?? null };
    },
    listAllTeamPermissions: async () =>
      (await readList(teamPermissionListSchema, "/team-permissions", { recursive: "false" })).items,
    listAllProjectPermissions: async () =>
      (await readList(projectPermissionListSchema, "/project-permissions", { recursive: "false" })).items,
    listTeamsPage: async (cursor, limit) => {
      const page = await readList(teamListSchema, "/teams", { limit: String(limit), cursor: cursor ?? undefined });
      return { items: page.items, nextCursor: page.pagination?.next_cursor ?? null };
    },
  };
}
