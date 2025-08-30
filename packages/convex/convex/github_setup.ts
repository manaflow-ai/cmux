import { env } from "../_shared/convex-env";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";

function safeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let res = 0;
  for (let i = 0; i < a.length; i++) res |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return res === 0;
}

function base64urlToBytes(s: string): Uint8Array {
  const abc =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let buffer = 0;
  let bits = 0;
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    const val = abc.indexOf(s[i]!);
    if (val === -1) continue;
    buffer = (buffer << 6) | val;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}

function base64urlFromBytes(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  const abc =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const x = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += abc[(x >> 18) & 63];
    out += abc[(x >> 12) & 63];
    out += abc[(x >> 6) & 63];
    out += abc[x & 63];
  }
  if (i + 1 === bytes.length) {
    const x = bytes[i] << 16;
    out += abc[(x >> 18) & 63];
    out += abc[(x >> 12) & 63];
  } else if (i < bytes.length) {
    const x = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += abc[(x >> 18) & 63];
    out += abc[(x >> 12) & 63];
    out += abc[(x >> 6) & 63];
  }
  return out;
}

export const githubSetup = httpAction(async (ctx, req) => {
  if (!env.INSTALL_STATE_SECRET) {
    return new Response("setup not configured", { status: 501 });
  }

  const url = new URL(req.url);
  const installationIdStr = url.searchParams.get("installation_id");
  const state = url.searchParams.get("state");
  if (!installationIdStr || !state) {
    return new Response("missing params", { status: 400 });
  }
  const installationId = Number(installationIdStr);
  if (!Number.isFinite(installationId)) {
    return new Response("invalid installation_id", { status: 400 });
  }

  // Parse token: v1.<payload>.<sig>
  const parts = state.split(".");
  if (parts.length !== 3) return new Response("invalid state", { status: 400 });
  let payloadStr = "";
  const version = parts[0];
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(env.INSTALL_STATE_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  if (version === "v2") {
    const payloadBytes = base64urlToBytes(parts[1] ?? "");
    payloadStr = new TextDecoder().decode(payloadBytes);
    const expectedSigB64 = parts[2] ?? "";
    const sigBuf = await crypto.subtle.sign(
      "HMAC",
      key,
      enc.encode(payloadStr)
    );
    const actualSigB64 = base64urlFromBytes(sigBuf);
    if (actualSigB64 !== expectedSigB64) {
      return new Response("invalid signature", { status: 400 });
    }
  } else if (version === "v1") {
    payloadStr = decodeURIComponent(parts[1] ?? "");
    const expectedSigHex = parts[2] ?? "";
    const sigBuf = await crypto.subtle.sign(
      "HMAC",
      key,
      enc.encode(payloadStr)
    );
    const actualSigHex = Array.from(new Uint8Array(sigBuf))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    if (!safeEqualHex(actualSigHex, expectedSigHex)) {
      return new Response("invalid signature", { status: 400 });
    }
  } else {
    return new Response("invalid state", { status: 400 });
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
    return new Response("invalid payload", { status: 400 });
  }

  const now = Date.now();
  if (payload.exp < now) {
    await ctx.runMutation(internal.github_app.consumeInstallState, {
      nonce: payload.nonce,
      expire: true,
    });
    return new Response("state expired", { status: 400 });
  }

  // Ensure nonce exists and is pending
  const row = await ctx.runQuery(internal.github_app.getInstallStateByNonce, {
    nonce: payload.nonce,
  });
  if (!row || row.status !== "pending") {
    return new Response("invalid state nonce", { status: 400 });
  }

  // Mark used
  await ctx.runMutation(internal.github_app.consumeInstallState, {
    nonce: payload.nonce,
  });

  // Map installation -> team (create or patch connection)
  await ctx.runMutation(
    internal.github_app.upsertProviderConnectionFromInstallation,
    {
      installationId,
      teamId: payload.teamId,
      connectedByUserId: payload.userId,
      isActive: true,
    }
  );

  // Resolve slug for nicer redirect when available
  const team = await ctx.runQuery(internal.teams.getByUuidInternal, {
    uuid: payload.teamId,
  });
  const teamPath = team?.slug ?? payload.teamId;
  const target = `http://localhost:5173/${encodeURIComponent(teamPath)}/environments`;
  return Response.redirect(target, 302);
});
