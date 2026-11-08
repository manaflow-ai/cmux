import { type AnyRouter, os } from "@orpc/server";
import { RPCHandler } from "@orpc/server/fetch";
import { DASHBOARD_ERRORS } from "../../orpc/server/dashboard/error-map";
import { dashboardRefusal } from "../../orpc/server/dashboard/errors";

/** Fake implementations keyed by procedure path, e.g. `"teams.detail"`. */
export type FakeProcedures = Record<string, (input: never) => unknown>;

export type RecordedCall = { readonly path: string; readonly input: unknown };

/** A declared refusal, as a procedure throws it. */
export const refuse = dashboardRefusal;

/**
 * A `fetch` that answers dashboard RPC calls from `procedures` through a real
 * RPC handler, so tests exercise the client's encoding and typed errors.
 * Other URLs go to `fallback` (404 by default).
 */
export function fakeDashboardRpcFetch(
  procedures: FakeProcedures,
  options: { readonly calls?: RecordedCall[]; readonly fallback?: typeof fetch } = {},
): typeof fetch {
  const base = os.errors(DASHBOARD_ERRORS);
  const router: Record<string, unknown> = {};
  for (const [path, implementation] of Object.entries(procedures)) {
    const parts = path.split(".");
    let node = router;
    for (const part of parts.slice(0, -1)) node = (node[part] ??= {}) as Record<string, unknown>;
    node[parts.at(-1)!] = base.handler(async ({ input }) => {
      options.calls?.push({ path, input });
      return (implementation as (input: unknown) => unknown)(input);
    });
  }
  const handler = new RPCHandler(router as AnyRouter);
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = input instanceof Request && init === undefined ? input : new Request(input, init);
    if (!new URL(request.url).pathname.startsWith("/api/dashboard/rpc/")) {
      return options.fallback ? options.fallback(input, init) : new Response("Not found", { status: 404 });
    }
    const { response } = await handler.handle(request, { prefix: "/api/dashboard/rpc", context: {} });
    return response ?? new Response("Not found", { status: 404 });
  }) as typeof fetch;
}

export type DeferredProcedure = {
  /** Resolves with the procedure input once the client calls it. */
  readonly input: Promise<unknown>;
  readonly succeed: (output: unknown) => void;
  readonly refuse: (status: number, reason: string) => void;
};

/**
 * Install a fetch whose single `path` call waits until the test answers it,
 * so a test can inspect optimistic state while the request is in flight.
 */
export function deferredProcedure(path: string): DeferredProcedure {
  let captured!: (input: unknown) => void;
  let settle!: { resolve: (output: unknown) => void; reject: (error: unknown) => void };
  const input = new Promise<unknown>((done) => {
    captured = done;
  });
  globalThis.fetch = fakeDashboardRpcFetch({
    [path]: (value: unknown) => {
      captured(value);
      return new Promise((resolve, reject) => {
        settle = { resolve, reject };
      });
    },
  });
  return {
    input,
    succeed: (output) => settle.resolve(output),
    refuse: (status, reason) => settle.reject(refuse(status, reason)),
  };
}
