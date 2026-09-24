import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
import {
  addAccount,
  parseCredential,
} from "../../../../services/coderouter/accounts";
import {
  resolveCoderouterUsageTeam,
  resolveCoderouterControlContext,
} from "../../../../services/coderouter/requestContext";
import { accountsWithUsage } from "../../../../services/coderouter/usage";
import { CodexSignatureError } from "../../../../services/coderouter/codexSignature";
import {
  accountWriteAccess,
  CoderouterSharedAccountError,
  teamPermissionRequired,
} from "../../../../services/coderouter/accountAdministration";
import { captureCoderouterEvent } from "../../../../services/coderouter/analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../services/coderouter/observability";


const MAX_BODY_BYTES = 128 * 1_024;

export const GET = coderouterControlRoute("accounts", "/api/coderouter/accounts", handleGet);

async function handleGet(request: Request): Promise<Response> {
  const startedAt = performance.now();
  const authStartedAt = performance.now();
  const resolved = await resolveCoderouterUsageTeam(request);
  if (!resolved.ok) return resolved.response;
  const authMs = performance.now() - authStartedAt;
  const result = await accountsWithUsage(resolved.teamId, resolved.access);
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
  readonly resolveContext: typeof resolveCoderouterControlContext;
  readonly add: typeof addAccount;
};

const defaultAccountsPostDependencies: AccountsPostDependencies = {
  resolveContext: resolveCoderouterControlContext,
  add: addAccount,
};

export const POST = coderouterControlRoute("accounts", "/api/coderouter/accounts", makeCoderouterAccountsPostHandler());

/**
 * Stores a provider account. Any team member may store a private one; sharing
 * it with the team needs account administration (accountAdministration.ts).
 * There is no account cap.
 */
export function makeCoderouterAccountsPostHandler(
  dependencies: AccountsPostDependencies = defaultAccountsPostDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
  const resolved = await dependencies.resolveContext(request);
  if (!resolved.ok) return resolved.response;
  const body = await readAccountBody(request);
  if (!body.ok) return body.response;
  const value = body.value;
  const requestedVisibility = value && typeof value === "object" && "visibility" in value ? (value as { visibility: unknown }).visibility : "private";
  if (requestedVisibility !== "private" && requestedVisibility !== "team") return Response.json({ error: "invalid_visibility" }, { status: 400 });
  // A VM mutation is scoped to its provisioned pool. Private visibility would
  // create an account that the same machine could not subsequently read on an
  // organization team, so machine writes are always team-visible.
  const visibility = resolved.value.access?.kind === "vm" ? "team" : requestedVisibility;
  const credential = parseCredential(value);
  if (!credential) {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  const team = resolved.value.team;
  if (visibility === "team" && !team.manageAccounts) {
    return teamPermissionRequired(team, "share_account", credential.provider === "codex" ? { addCommand: "codex" } : {});
  }
  try {
    const result = await dependencies.add(team.teamId, credential, undefined, undefined, undefined, {
      createdBy: resolved.value.user.id,
      visibility,
      access: accountWriteAccess(resolved.value),
    });
    captureCoderouterEvent({
      event: "coderouter_account_added",
      userId: resolved.value.user.id,
      teamId: team.teamId,
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
    return addFailed(error, team);
  }
  };
}

async function readAccountBody(
  request: Request,
): Promise<{ readonly ok: true; readonly value: unknown } | { readonly ok: false; readonly response: Response }> {
  const length = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    return { ok: false, response: Response.json({ error: "payload_too_large" }, { status: 413 }) };
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_BODY_BYTES) {
    return { ok: false, response: Response.json({ error: "payload_too_large" }, { status: 413 }) };
  }
  try {
    return { ok: true, value: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { ok: false, response: Response.json({ error: "invalid_request" }, { status: 400 }) };
  }
}

function addFailed(error: unknown, team: { readonly teamId: string; readonly teamName: string }): Response {
  if (error instanceof CodexSignatureError) {
    return Response.json({ error: "invalid_credential", message: "Sign in to Codex again before adding this account." }, { status: 400, headers: { "cache-control": "no-store" } });
  }
  // The credential matches an account shared with the team, and only account
  // administration may replace a shared account's credential.
  if (error instanceof CoderouterSharedAccountError) return teamPermissionRequired(team, "change_shared_account");
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

function timing(name: string, duration: number): string {
  return `${name};dur=${Math.max(0, duration).toFixed(1)}`;
}
