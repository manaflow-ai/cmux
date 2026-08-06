import { authenticateRouteToken, selectAccountForRequest } from "./repository";
import { freshCredential } from "./refresh";
import { fetchProviderRead } from "./providerFetch";

const OPENCODE_CONSOLE = "https://console.opencode.ai";

export async function openCodeClientConfig(request: Request): Promise<Response> {
  const auth = await routeIdentity(request);
  if (!auth) return Response.json({ error: "unauthorized" }, { status: 401 });
  const resolved = await openCodeAccount(auth.teamId);
  if (!resolved) return Response.json({ error: "no_usable_account" }, { status: 503 });
  const remote = await remoteConfig(resolved.credential.accessToken);
  const provider = rewriteProviders(remote, auth.token);
  return Response.json({ provider }, {
    headers: { "cache-control": "no-store" },
  });
}

export async function proxyOpenCodeRequest(
  request: Request,
  providerId: string,
  path: readonly string[],
): Promise<Response> {
  const auth = await routeIdentity(request);
  if (!auth) return Response.json({ error: "unauthorized" }, { status: 401 });
  const resolved = await openCodeAccount(auth.teamId);
  if (!resolved) return Response.json({ error: "no_usable_account" }, { status: 503 });
  const config = await remoteConfig(resolved.credential.accessToken);
  const provider = config[providerId];
  if (!isRecord(provider)) {
    return Response.json({ error: "unknown_provider" }, { status: 404 });
  }
  const api = provider.api;
  const base = isRecord(api) ? api.url : undefined;
  if (typeof base !== "string" || !safeProviderURL(base)) {
    return Response.json({ error: "invalid_provider" }, { status: 502 });
  }
  const target = new URL(base);
  target.pathname = `${target.pathname.replace(/\/+$/, "")}/${path
    .map(encodeURIComponent)
    .join("/")}`;
  target.search = new URL(request.url).search;

  const headers = new Headers();
  for (const name of ["accept", "content-type", "user-agent"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  headers.set("authorization", `Bearer ${resolved.credential.accessToken}`);
  const upstream = await fetch(target, {
    method: request.method,
    headers,
    body: request.method === "GET" || request.method === "HEAD"
      ? undefined
      : request.body,
    duplex: "half",
    cache: "no-store",
  } as RequestInit & { duplex: "half" });
  return new Response(upstream.body, {
    status: upstream.status,
    headers: filteredResponseHeaders(upstream.headers),
  });
}

async function openCodeAccount(
  teamId: string,
  dependencies = {
    select: selectAccountForRequest,
    credential: freshCredential,
  },
) {
  const attempted: string[] = [];
  for (let attempt = 0; attempt < 8; attempt++) {
    const account = await dependencies.select(
      teamId,
      "opencode-go",
      attempted,
    );
    if (!account) return null;
    attempted.push(account.id);
    try {
      const credential = await dependencies.credential({
        teamId,
        accountId: account.id,
        expectedRevision: account.vaultRevision,
      });
      if (credential.provider === "opencode-go") {
        return { account, credential };
      }
    } catch {
      // Broken, refreshing, and transiently unavailable accounts are skipped.
    }
  }
  return null;
}

async function remoteConfig(accessToken: string): Promise<Record<string, unknown>> {
  const response = await fetchProviderRead(() => fetch(`${OPENCODE_CONSOLE}/api/config`, {
    headers: { authorization: `Bearer ${accessToken}` },
    cache: "no-store",
    signal: AbortSignal.timeout(5_000),
  }));
  if (!response.ok) throw new Error(`OpenCode config failed: ${response.status}`);
  const value: unknown = await response.json();
  if (!isRecord(value) || !isRecord(value.config) || !isRecord(value.config.provider)) {
    throw new Error("OpenCode returned an invalid provider catalog");
  }
  return value.config.provider;
}

function rewriteProviders(
  providers: Record<string, unknown>,
  routeToken: string,
): Record<string, unknown> {
  return Object.fromEntries(Object.entries(providers).flatMap(([id, value]) => {
    if (!isRecord(value)) return [];
    const api = value.api;
    const npm = isRecord(api) && typeof api.package === "string"
      ? api.package
      : typeof value.npm === "string"
      ? value.npm
      : undefined;
    const models = isRecord(value.models)
      ? Object.fromEntries(Object.entries(value.models).map(([modelId, model]) => {
        if (!isRecord(model)) return [modelId, model];
        const nestedProvider = isRecord(model.provider) ? model.provider : undefined;
        return [modelId, {
          ...model,
          ...(nestedProvider
            ? {
              provider: {
                ...nestedProvider,
                api: `https://coderouter.dev/api/coderouter/opencode/proxy/${encodeURIComponent(id)}`,
              },
            }
            : {}),
        }];
      }))
      : value.models;
    return [[id, {
      ...value,
      ...(npm ? { npm } : {}),
      api: undefined,
      models,
      options: {
        ...(isRecord(value.options) ? withoutSecrets(value.options) : {}),
        baseURL: `https://coderouter.dev/api/coderouter/opencode/proxy/${encodeURIComponent(id)}`,
        apiKey: routeToken,
      },
    }]];
  }));
}

function withoutSecrets(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).filter(([key]) =>
      !["apiKey", "token", "accessToken", "refreshToken", "headers"].includes(key)
    ),
  );
}

async function routeIdentity(
  request: Request,
): Promise<{ teamId: string; token: string } | null> {
  const header = request.headers.get("authorization")?.trim() ?? "";
  const token = /^Bearer[ \t]+(.+)$/i.exec(header)?.[1]?.trim();
  if (!token) return null;
  const identity = await authenticateRouteToken(token);
  return identity ? { ...identity, token } : null;
}

function safeProviderURL(value: string): boolean {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password) return false;
    const hostname = url.hostname.toLowerCase();
    return hostname !== "localhost" &&
      hostname !== "0.0.0.0" &&
      hostname !== "::1" &&
      !/^127\./.test(hostname) &&
      !/^10\./.test(hostname) &&
      !/^192\.168\./.test(hostname) &&
      !/^172\.(1[6-9]|2[0-9]|3[01])\./.test(hostname);
  } catch {
    return false;
  }
}

function filteredResponseHeaders(input: Headers): Headers {
  const headers = new Headers({ "cache-control": "no-store" });
  for (const name of ["content-type", "x-request-id"]) {
    const value = input.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export const __test = { rewriteProviders, safeProviderURL, openCodeAccount };
