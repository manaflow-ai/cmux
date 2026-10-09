import { Hono } from "hono";
import { requireUser } from "../auth";
import type { HonoEnv } from "../context";
import { randomCode, randomId, randomToken, sha256Hex } from "../crypto";
import { ApiError, notFound } from "../errors";
import { rateLimit, readJson, str } from "../http";
import type { Host } from "../repo/types";
import { notifyHostRemoved, onlineHostIds } from "../signal/client";

export const PAIRING_TTL_MS = 10 * 60 * 1000;
export const PAIRING_INTERVAL_S = 5;
/** How long after approval the host may still collect its token. */
export const PAIRING_CLAIM_WINDOW_MS = 10 * 60 * 1000;

export const hostView = (h: Host, online: boolean) => ({
  id: h.id,
  name: h.name,
  os: h.os,
  online,
  lastSeenAt: h.lastSeenAt,
  createdAt: h.createdAt,
});

/** `ABCD-EFGH` display form of an 8-char user code. */
export const formatUserCode = (code: string) => `${code.slice(0, 4)}-${code.slice(4)}`;
export const normalizeUserCode = (raw: string) => raw.toUpperCase().replace(/[^A-Z0-9]/g, "");

export const hostRoutes = new Hono<HonoEnv>();

hostRoutes.post("/pair/start", async (c) => {
  await rateLimit(c, "pair");
  const { repo, deps } = c.var;
  const body = await readJson(c);
  const name = str(body, "name", { max: 200 }).trim();
  const os = str(body, "os", { max: 64 }).trim();
  const now = deps.now();
  const deviceCode = randomToken("dc");
  const userCode = randomCode(8);
  const expiresAt = now + PAIRING_TTL_MS;
  await repo.createPairing({
    id: randomId("pr"),
    deviceCodeHash: await sha256Hex(deviceCode),
    userCode,
    name,
    os,
    userId: null,
    hostId: null,
    expiresAt,
    approvedAt: null,
    claimedAt: null,
    createdAt: now,
  });
  return c.json({ deviceCode, userCode: formatUserCode(userCode), expiresAt, interval: PAIRING_INTERVAL_S });
});

hostRoutes.post("/pair/poll", async (c) => {
  await rateLimit(c, "pair");
  const { repo, deps } = c.var;
  const deviceCode = str(await readJson(c), "deviceCode", { max: 256 });
  const now = deps.now();
  const pairing = await repo.getPairingByDeviceCodeHash(await sha256Hex(deviceCode));
  if (!pairing) throw notFound("unknown device code");
  if (pairing.approvedAt === null) {
    if (pairing.expiresAt <= now) throw new ApiError("not_found", "pairing expired", 410);
    return c.json({ status: "pending" });
  }
  if (pairing.claimedAt !== null || !pairing.hostId || !pairing.userId) throw new ApiError("not_found", "pairing already claimed", 410);
  if (pairing.approvedAt + PAIRING_CLAIM_WINDOW_MS <= now) throw new ApiError("not_found", "pairing expired", 410);
  if (!(await repo.claimPairing(pairing.id, now))) throw new ApiError("not_found", "pairing already claimed", 410);
  const hostToken = randomToken("ht");
  await repo.setHostToken(pairing.hostId, await sha256Hex(hostToken));
  return c.json({ status: "approved", hostId: pairing.hostId, hostToken, userId: pairing.userId });
});

hostRoutes.post("/pair/approve", requireUser, async (c) => {
  const { repo, deps, principal } = c.var;
  const userCode = normalizeUserCode(str(await readJson(c), "userCode", { max: 32 }));
  const now = deps.now();
  const pairing = await repo.getPendingPairingByUserCode(userCode, now);
  if (!pairing) throw notFound("unknown or expired code");
  const host: Host = {
    id: randomId("h"),
    userId: principal.userId,
    name: pairing.name,
    os: pairing.os,
    tokenHash: null,
    lastSeenAt: null,
    createdAt: now,
  };
  // Create the host before approving so a poll right after approval finds it.
  await repo.createHost(host);
  if (!(await repo.approvePairing(pairing.id, principal.userId, host.id, now))) {
    await repo.deleteHost(host.id, principal.userId);
    throw notFound("unknown or expired code");
  }
  return c.json({ host: hostView(host, false) });
});

hostRoutes.get("/", requireUser, async (c) => {
  const { repo, principal } = c.var;
  const [hosts, online] = await Promise.all([repo.listHosts(principal.userId), onlineHostIds(c.env, principal.userId)]);
  return c.json({ hosts: hosts.map((h) => hostView(h, online.has(h.id))) });
});

hostRoutes.delete("/:id", requireUser, async (c) => {
  const { repo, principal } = c.var;
  const id = c.req.param("id");
  if (!(await repo.deleteHost(id, principal.userId))) throw notFound("host not found");
  await notifyHostRemoved(c.env, principal.userId, id);
  return c.json({});
});
