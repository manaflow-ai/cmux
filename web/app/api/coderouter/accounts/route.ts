import {
  addAccount,
  parseCredential,
} from "../../../../services/coderouter/accounts";
import {
  resolveCoderouterUsageTeam,
  resolveCodeRouterRequestContext,
} from "../../../../services/coderouter/requestContext";
import { accountsWithUsage } from "../../../../services/coderouter/usage";
import { captureCoderouterEvent } from "../../../../services/coderouter/analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../services/coderouter/observability";


const MAX_BODY_BYTES = 128 * 1_024;

export async function GET(request: Request): Promise<Response> {
  const startedAt = performance.now();
  const authStartedAt = performance.now();
  const resolved = await resolveCoderouterUsageTeam(request);
  if (!resolved.ok) return resolved.response;
  const authMs = performance.now() - authStartedAt;
  const result = await accountsWithUsage(resolved.teamId);
  const serializeStartedAt = performance.now();
  const body = JSON.stringify({
    teamId: resolved.teamId,
    accounts: result.accounts,
    usageAsOf: result.usageAsOf,
    usageAgeSeconds: Math.max(
      0,
      Math.floor((Date.now() - result.usageGeneratedAtMs) / 1_000),
    ),
    cacheMaxAgeSeconds: result.cacheMaxAgeSeconds,
  });
  const serializeMs = performance.now() - serializeStartedAt;
  const serverTiming = [
    timing("auth", authMs),
    timing("rds", result.timing.rdsMs),
    timing("provider", result.timing.providerMs),
    timing("serialize", serializeMs),
    timing("total", performance.now() - startedAt),
  ].join(", ");
  captureCoderouterEvent({
    event: "coderouter_account_status_viewed",
    teamId: resolved.teamId,
    properties: {
      source: "native_api",
      account_count: result.accounts.length,
      account_error_count: result.accounts.filter(
        (account) => "usageError" in account && Boolean(account.usageError),
      ).length,
      duration_ms: Math.round(performance.now() - startedAt),
    },
  });
  addCoderouterBreadcrumb("status", "Account status loaded", {
    account_count: result.accounts.length,
    duration_ms: Math.round(performance.now() - startedAt),
  });
  return new Response(body, {
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
      "server-timing": serverTiming,
      // Vercel may reserve/strip Server-Timing at the edge. Keep the same
      // standards-formatted value observable under a product header.
      "x-coderouter-server-timing": serverTiming,
    },
  });
}

type AccountsPostDependencies = {
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly add: typeof addAccount;
};

const defaultAccountsPostDependencies: AccountsPostDependencies = {
  resolveContext: resolveCodeRouterRequestContext,
  add: addAccount,
};

export const POST = makeCoderouterAccountsPostHandler();

export function makeCoderouterAccountsPostHandler(
  dependencies: AccountsPostDependencies = defaultAccountsPostDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
  // Team membership is the only requirement; there is no account cap.
  const resolved = await dependencies.resolveContext(request);
  if (!resolved.ok) return resolved.response;
  const length = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    return Response.json({ error: "payload_too_large" }, { status: 413 });
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_BODY_BYTES) {
    return Response.json({ error: "payload_too_large" }, { status: 413 });
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  const credential = parseCredential(value);
  if (!credential) {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  try {
    const result = await dependencies.add(resolved.value.team.teamId, credential);
    captureCoderouterEvent({
      event: "coderouter_account_added",
      userId: resolved.value.user.id,
      teamId: resolved.value.team.teamId,
      properties: {
        provider: credential.provider,
        source: "native_api",
        already_exists: result.alreadyExists,
      },
    });
    addCoderouterBreadcrumb("account", "Provider account stored", {
      provider: credential.provider,
      already_exists: result.alreadyExists,
    });
    return Response.json(result, {
      status: result.alreadyExists ? 200 : 201,
      headers: { "cache-control": "no-store" },
    });
  } catch (error) {
    reportCoderouterFailure("rds", error, { operation: "add_account" });
    return Response.json(
      {
        error: "account_store_unavailable",
        message:
          "coderouter could not store this account. Your local provider sign-in was not removed; retry `cr add` shortly.",
        retryable: true,
      },
      {
        status: 503,
        headers: {
          "cache-control": "no-store",
          "retry-after": "5",
        },
      },
    );
  }
  };
}

function timing(name: string, duration: number): string {
  return `${name};dur=${Math.max(0, duration).toFixed(1)}`;
}
