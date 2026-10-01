import type { Viewer } from "@mux/protocol";
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import type { Env } from "./env.ts";

const STACK_API = "https://api.stack-auth.com";
const keySets = new Map<string, JWTVerifyGetKey>();

function stackKeys(projectId: string): JWTVerifyGetKey {
  let keys = keySets.get(projectId);
  if (!keys) {
    keys = createRemoteJWKSet(
      new URL(`${STACK_API}/api/v1/projects/${projectId}/.well-known/jwks.json`),
      {
        cacheMaxAge: 10 * 60_000,
        cooldownDuration: 30_000,
      },
    );
    keySets.set(projectId, keys);
  }
  return keys;
}

/**
 * The signed-in human: a Stack Auth access token (Authorization header, or
 * `access_token` query for WebSockets) verified against Stack's published keys.
 * With MUX_DEV_AUTH=1 (local only), `dev_user` is accepted too.
 */
export async function authenticate(request: Request, env: Env): Promise<Viewer | undefined> {
  const url = new URL(request.url);
  const token =
    request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1] ??
    url.searchParams.get("access_token");
  if (token && env.MUX_STACK_PROJECT_ID) {
    const viewer = await verifyStackToken(token, env.MUX_STACK_PROJECT_ID);
    if (viewer) return viewer;
  }
  if (env.MUX_DEV_AUTH === "1") {
    const devUser = url.searchParams.get("dev_user") ?? request.headers.get("x-mux-dev-user");
    if (devUser && /^[a-z0-9-]{1,40}$/.test(devUser))
      return { id: `dev-${devUser}`, displayName: devUser };
  }
  return undefined;
}

async function verifyStackToken(token: string, projectId: string): Promise<Viewer | undefined> {
  try {
    const { payload } = await jwtVerify(token, stackKeys(projectId), {
      algorithms: ["ES256"],
      issuer: `${STACK_API}/api/v1/projects/${projectId}`,
      audience: projectId,
      clockTolerance: 60,
    });
    if (typeof payload.sub !== "string" || !payload.sub || payload.is_anonymous === true)
      return undefined;
    const name = typeof payload.name === "string" && payload.name ? payload.name : undefined;
    const email = typeof payload.email === "string" ? payload.email : undefined;
    return { id: payload.sub, displayName: name ?? email?.split("@")[0] ?? "you" };
  } catch {
    return undefined;
  }
}
