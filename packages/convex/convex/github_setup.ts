import { env } from "../_shared/convex-env";
import {
  base64urlFromBytes,
  base64urlToBytes,
  bytesToHex,
} from "../_shared/encoding";
import { hmacSha256, safeEqualHex } from "../_shared/crypto";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";

type InstallationAccountInfo = {
  accountLogin: string;
  accountId?: number;
  accountType?: "Organization" | "User";
};

const textEncoder = new TextEncoder();
const privateKeyCache = new Map<string, CryptoKey>();

function pemToDer(pem: string): Uint8Array {
  const cleaned = pem
    .replace(/-----BEGIN [A-Z ]+-----/g, "")
    .replace(/-----END [A-Z ]+-----/g, "")
    .replace(/\s+/g, "");
  const base64Url = cleaned
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
  return base64urlToBytes(base64Url);
}

function base64urlEncodeJson(value: unknown): string {
  return base64urlFromBytes(textEncoder.encode(JSON.stringify(value)));
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const cached = privateKeyCache.get(pem);
  if (cached) return cached;
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) {
    throw new Error("SubtleCrypto is not available in this environment");
  }
  const der = pemToDer(pem);
  const keyData =
    der.byteOffset === 0 && der.byteLength === der.buffer.byteLength
      ? der
      : der.slice();
  const key = await subtle.importKey(
    "pkcs8",
    keyData,
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256",
    },
    false,
    ["sign"]
  );
  privateKeyCache.set(pem, key);
  return key;
}

async function createGithubAppJwt(
  appId: string,
  privateKey: string
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" } as const;
  const payload = {
    iat: now - 60,
    exp: now + 600,
    iss: appId,
  } as const;
  const signingInput = `${base64urlEncodeJson(header)}.${base64urlEncodeJson(
    payload
  )}`;
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) {
    throw new Error("SubtleCrypto is not available in this environment");
  }
  const key = await importPrivateKey(privateKey);
  const signature = await subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    textEncoder.encode(signingInput)
  );
  const signaturePart = base64urlFromBytes(new Uint8Array(signature));
  return `${signingInput}.${signaturePart}`;
}

function normalizeAccountType(
  input: unknown
): InstallationAccountInfo["accountType"] {
  return input === "Organization" || input === "User"
    ? input
    : undefined;
}

async function fetchInstallationAccountInfo(
  installationId: number
): Promise<InstallationAccountInfo | null> {
  const appId = env.CMUX_GITHUB_APP_ID;
  const privateKey = env.CMUX_GITHUB_APP_PRIVATE_KEY;
  if (!appId || !privateKey) {
    return null;
  }

  try {
    const normalizedPrivateKey = privateKey.replace(/\\n/g, "\n");
    const jwt = await createGithubAppJwt(appId, normalizedPrivateKey);
    const response = await fetch(
      `https://api.github.com/app/installations/${installationId}`,
      {
        headers: {
          Authorization: `Bearer ${jwt}`,
          Accept: "application/vnd.github+json",
          "User-Agent": "cmux-github-setup",
        },
      }
    );

    if (!response.ok) {
      const errorText = await response.text();
      console.error(
        `[github_setup] Failed to fetch installation ${installationId} info (status ${response.status}): ${errorText}`
      );
      return null;
    }

    const data = (await response.json()) as {
      account?: {
        login?: string | null;
        id?: number | null;
        type?: string | null;
      };
    };

    const login = data.account?.login ?? undefined;
    if (!login) {
      return null;
    }

    return {
      accountLogin: login,
      accountId:
        typeof data.account?.id === "number" ? data.account?.id : undefined,
      accountType: normalizeAccountType(data.account?.type ?? undefined),
    };
  } catch (error) {
    console.error(
      `[github_setup] Unexpected error fetching installation ${installationId} info`,
      error
    );
    return null;
  }
}

export const githubSetup = httpAction(async (ctx, req) => {
  const url = new URL(req.url);
  const installationIdStr = url.searchParams.get("installation_id");
  const state = url.searchParams.get("state");
  const base = env.BASE_APP_URL.replace(/\/$/, "");
  const toCmuxDeepLink = (team?: string | null) =>
    `cmux://github-connect-complete${team ? `?team=${encodeURIComponent(team)}` : ""}`;

  if (!installationIdStr) {
    return new Response("missing params", { status: 400 });
  }
  const installationId = Number(installationIdStr);
  if (!Number.isFinite(installationId)) {
    return new Response("invalid installation_id", { status: 400 });
  }

  // If state is missing (e.g. user used "Configure" from GitHub settings),
  // try to resolve the target team from an existing connection and redirect.
  if (!state) {
    const existing = await ctx.runQuery(
      internal.github_app.getProviderConnectionByInstallationId,
      { installationId }
    );
    if (existing && existing.teamId) {
      const team = await ctx.runQuery(internal.teams.getByTeamIdInternal, {
        teamId: existing.teamId,
      });
      const teamPath = team?.slug ?? existing.teamId;
      // Prefer deep-linking back to the app to finish the flow
      return Response.redirect(toCmuxDeepLink(teamPath), 302);
    }
    // Fallback: send user to team picker if we can't resolve a team
    return Response.redirect(`${base}/team-picker`, 302);
  }

  if (!env.INSTALL_STATE_SECRET) {
    return new Response("setup not configured", { status: 501 });
  }

  // Parse token: v1.<payload>.<sig>
  const parts = state.split(".");
  if (parts.length !== 3) {
    // Fallback to deep link if state is malformed
    return Response.redirect(toCmuxDeepLink(), 302);
  }
  let payloadStr = "";
  const version = parts[0];

  if (version === "v2") {
    const payloadBytes = base64urlToBytes(parts[1] ?? "");
    payloadStr = new TextDecoder().decode(payloadBytes);
    const expectedSigB64 = parts[2] ?? "";
    const sigBuf = await hmacSha256(env.INSTALL_STATE_SECRET, payloadStr);
    const actualSigB64 = base64urlFromBytes(sigBuf);
    if (actualSigB64 !== expectedSigB64) {
      return Response.redirect(toCmuxDeepLink(), 302);
    }
  } else if (version === "v1") {
    payloadStr = decodeURIComponent(parts[1] ?? "");
    const expectedSigHex = parts[2] ?? "";
    const sigBuf = await hmacSha256(env.INSTALL_STATE_SECRET, payloadStr);
    const actualSigHex = bytesToHex(sigBuf);
    if (!safeEqualHex(actualSigHex, expectedSigHex)) {
      return Response.redirect(toCmuxDeepLink(), 302);
    }
  } else {
    return Response.redirect(toCmuxDeepLink(), 302);
  }

  type Payload = {
    ver: 1;
    teamId: string;
    userId: string;
    iat: number;
    exp: number;
    nonce: string;
  };
  let payload: Payload;
  try {
    payload = JSON.parse(payloadStr) as Payload;
  } catch {
    return Response.redirect(toCmuxDeepLink(), 302);
  }

  const now = Date.now();
  if (payload.exp < now) {
    await ctx.runMutation(internal.github_app.consumeInstallState, {
      nonce: payload.nonce,
      expire: true,
    });
    // Expired state: still bring user back to the app to retry
    return Response.redirect(toCmuxDeepLink(), 302);
  }

  // Ensure nonce exists and is pending
  const row = await ctx.runQuery(internal.github_app.getInstallStateByNonce, {
    nonce: payload.nonce,
  });
  if (!row || row.status !== "pending") {
    // State already consumed or unknown. Bring the user back to the app,
    // where we can surface any missing connection.
    return Response.redirect(toCmuxDeepLink(), 302);
  }

  // Mark used
  await ctx.runMutation(internal.github_app.consumeInstallState, {
    nonce: payload.nonce,
  });

  // Map installation -> team (create or patch connection)
  const accountInfo = await fetchInstallationAccountInfo(installationId);
  if (accountInfo) {
    console.log(
      `[github_setup] Installation ${installationId} account=${accountInfo.accountLogin} type=${accountInfo.accountType ?? "unknown"}`
    );
  } else {
    console.warn(
      `[github_setup] No account metadata fetched for installation ${installationId}`
    );
  }
  await ctx.runMutation(
    internal.github_app.upsertProviderConnectionFromInstallation,
    {
      installationId,
      teamId: payload.teamId,
      connectedByUserId: payload.userId,
      isActive: true,
      ...(accountInfo?.accountLogin
        ? { accountLogin: accountInfo.accountLogin }
        : {}),
      ...(accountInfo?.accountId !== undefined
        ? { accountId: accountInfo.accountId }
        : {}),
      ...(accountInfo?.accountType
        ? { accountType: accountInfo.accountType }
        : {}),
    }
  );

  // Resolve slug for nicer redirect when available
  const team = await ctx.runQuery(internal.teams.getByTeamIdInternal, {
    teamId: payload.teamId,
  });
  const teamPath = team?.slug ?? payload.teamId;
  // Prefer deep link back into the app so Electron foregrounds and refreshes.
  return Response.redirect(toCmuxDeepLink(teamPath), 302);
});
