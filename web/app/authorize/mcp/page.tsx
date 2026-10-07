import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { directDevBackendOrigin } from "../../lib/direct-dev-backend-origin";
import { mcpIssuerFor } from "../../../services/mcp/oauthRoutes";
import { authorizationRedirect, MCP_AUTHORIZE_PATH } from "../../../services/mcp/oauth";
import {
  AUTHORIZATION_PARAM_NAMES,
  authorizationParams,
  consentUserFromCookies,
  MCP_SCOPE_DESCRIPTIONS,
  validateConsentRequest,
} from "../../../services/mcp/oauthConsent";

export const dynamic = "force-dynamic";

type McpAuthorizePageProps = {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

async function pageOrigin(): Promise<string> {
  const direct = directDevBackendOrigin(process.env)?.origin;
  if (direct) return direct;
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "cmux.com";
  const proto = requestHeaders.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  return `${proto}://${host}`;
}

function searchParamsFrom(raw: Record<string, string | string[] | undefined>): URLSearchParams {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(raw)) {
    const first = Array.isArray(value) ? value[0] : value;
    if (first !== undefined) params.set(key, first);
  }
  return authorizationParams(params);
}

function clientLabel(clientId: string, clientName: string | null): string {
  if (clientName) return clientName;
  try {
    return new URL(clientId).hostname;
  } catch {
    return "An MCP client";
  }
}

function ErrorCard({ message }: { message: string }) {
  return (
    <main className="flex min-h-screen items-center justify-center bg-black px-6 text-white">
      <section className="w-full max-w-sm">
        <p className="mb-8 text-sm text-neutral-500">cmux Cloud</p>
        <h1 className="text-2xl font-medium tracking-tight">This connection link does not work</h1>
        <p className="mt-2 text-sm leading-6 text-neutral-400">{message}</p>
        <p className="mt-2 text-sm leading-6 text-neutral-400">Go back to the app that sent you here and connect cmux again.</p>
      </section>
    </main>
  );
}

export default async function McpAuthorizePage({ searchParams }: McpAuthorizePageProps) {
  const origin = mcpIssuerFor(await pageOrigin());
  const params = searchParamsFrom(await searchParams);
  const validated = await validateConsentRequest(params, origin);
  if (!validated.ok) {
    if (validated.redirectable && validated.redirectUri) {
      redirect(authorizationRedirect(validated.redirectUri, origin, {
        error: validated.error.error,
        error_description: validated.error.description,
        state: validated.state,
      }));
    }
    return <ErrorCard message={validated.error.description} />;
  }
  const user = await consentUserFromCookies();
  if (!user) {
    const returnTo = `${MCP_AUTHORIZE_PATH}?${params.toString()}`;
    redirect(`/handler/sign-in?after_auth_return_to=${encodeURIComponent(returnTo)}`);
  }
  const { request } = validated;
  const client = clientLabel(request.client.clientId, request.client.clientName);
  const defaultTeamId = user.selectedTeamId ?? user.teams[0]?.id;
  const switchAccount = `/handler/sign-out-and-sign-in?after_auth_return_to=${encodeURIComponent(
    `/handler/sign-in?after_auth_return_to=${encodeURIComponent(`${MCP_AUTHORIZE_PATH}?${params.toString()}`)}`,
  )}`;

  return (
    <main className="flex min-h-screen items-center justify-center bg-black px-6 py-12 text-white">
      <section className="w-full max-w-md">
        <p className="mb-8 text-sm text-neutral-500">cmux Cloud</p>
        <h1 className="text-2xl font-medium tracking-tight">Connect {client} to cmux</h1>
        <p className="mt-2 text-sm leading-6 text-neutral-400">
          Signed in as <bdi className="text-neutral-200">{user.email ?? user.name ?? user.id}</bdi>.{" "}
          <a className="underline underline-offset-2 hover:text-neutral-200" href={switchAccount}>Use another account</a>
        </p>
        <form action="/api/oauth/authorize" className="mt-8 space-y-6" method="post">
          {AUTHORIZATION_PARAM_NAMES.map((name) => {
            const value = params.get(name);
            return value === null ? null : <input key={name} name={name} type="hidden" value={value} />;
          })}
          {user.teams.length > 0 ? (
            <div>
              <label className="text-sm font-medium" htmlFor="team_id">Team</label>
              <p className="mt-1 text-sm text-neutral-500">Machines are created on this team and use its plan.</p>
              <select
                className="mt-2 h-11 w-full rounded-md border border-neutral-800 bg-neutral-950 px-3 text-sm outline-none focus:border-neutral-600"
                defaultValue={defaultTeamId}
                id="team_id"
                name="team_id"
              >
                {user.teams.map((team) => <option key={team.id} value={team.id}>{team.name}</option>)}
              </select>
            </div>
          ) : null}
          <fieldset>
            <legend className="text-sm font-medium">{client} will be able to</legend>
            <div className="mt-2 space-y-2">
              {request.scopes.map((scope) => (
                <label className="flex items-start gap-3 text-sm text-neutral-300" key={scope}>
                  <input className="mt-1" defaultChecked name="approved_scope" type="checkbox" value={scope} />
                  <span>{MCP_SCOPE_DESCRIPTIONS[scope]}</span>
                </label>
              ))}
            </div>
          </fieldset>
          <p className="text-xs leading-5 text-neutral-500">
            You can disconnect at any time from {client}. Machines and agents use your plan&apos;s limits.
          </p>
          <div className="flex gap-3">
            <button
              className="h-11 flex-1 rounded-md border border-neutral-800 text-sm font-medium hover:bg-neutral-900"
              name="decision"
              type="submit"
              value="deny"
            >
              Cancel
            </button>
            <button
              className="h-11 flex-1 rounded-md bg-white text-sm font-medium text-black hover:bg-neutral-200"
              name="decision"
              type="submit"
              value="approve"
            >
              Allow
            </button>
          </div>
        </form>
      </section>
    </main>
  );
}
