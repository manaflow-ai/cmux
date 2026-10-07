/**
 * @cmux/vm: TypeScript client for the cmux VM API.
 *
 * `schema.d.ts` is generated from workers/cmux-vm/openapi.json by
 * openapi-typescript (`bun run generate`); CI regenerates it and fails on any
 * difference. This file only adds the default host and authentication.
 */
import createClient, { type Client } from "openapi-fetch";
import type { components, paths } from "./schema.d.ts";

export type { components, operations, paths } from "./schema.d.ts";

/** The production cmux VM API. */
export const DEFAULT_BASE_URL = "https://vm.cmux.dev";

/** The header that names the team a session token acts for. */
export const TEAM_HEADER = "x-cmux-team-id";

export type Vm = components["schemas"]["Vm"];
export type VmList = components["schemas"]["VmList"];
export type VmState = Vm["state"];
export type CreateVmRequest = components["schemas"]["CreateVmRequest"];
export type ForkVmRequest = components["schemas"]["ForkVmRequest"];

export type CmuxVmClient = Client<paths>;

export interface CmuxVmClientOptions {
  /** A cmux VM API key (`cmuxvm_sk_...`) or a cmux session token. */
  readonly token: string;
  /** Team the token acts for; required with session tokens, optional with API keys. */
  readonly teamId?: string;
  /** Defaults to {@link DEFAULT_BASE_URL}. */
  readonly baseUrl?: string;
  /** Custom fetch, for tests or runtimes without a global fetch. */
  readonly fetch?: (request: Request) => Promise<Response>;
}

/**
 * Creates a typed client. Every call returns `{ data, error, response }`;
 * check `response.status` to tell, for example, 404 (not found) from 401.
 *
 * ```ts
 * const vm = createCmuxVmClient({ token: process.env.CMUX_VM_API_KEY! });
 * const { data, error } = await vm.GET("/v1/vms/{vmId}", { params: { path: { vmId } } });
 * ```
 */
export function createCmuxVmClient(options: CmuxVmClientOptions): CmuxVmClient {
  const headers: Record<string, string> = { authorization: `Bearer ${options.token}` };
  if (options.teamId !== undefined) headers[TEAM_HEADER] = options.teamId;
  return createClient<paths>({
    baseUrl: (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, ""),
    headers,
    ...(options.fetch === undefined ? {} : { fetch: options.fetch }),
  });
}
