import type { AppEnv } from "../env";

/** Worker-side handle to a user's SignalRoom. Internal routes are not reachable from the internet. */
export function signalRoom(env: AppEnv, userId: string): DurableObjectStub {
  return env.SIGNAL_ROOM.get(env.SIGNAL_ROOM.idFromName(userId));
}

export async function onlineHostIds(env: AppEnv, userId: string): Promise<Set<string>> {
  try {
    const res = await signalRoom(env, userId).fetch("https://signal/internal/online");
    const body = (await res.json()) as { hostIds?: string[] };
    return new Set(body.hostIds ?? []);
  } catch (err) {
    console.error("signal online lookup failed", err instanceof Error ? err.message : err);
    return new Set();
  }
}

/**
 * Per-user sliding-window rate limit kept in the user's SignalRoom.
 * Fails open if the room is unreachable.
 */
export async function userRateLimit(env: AppEnv, userId: string, key: string, max: number, windowMs: number): Promise<boolean> {
  try {
    const q = new URLSearchParams({ key, max: String(max), windowMs: String(windowMs) });
    const res = await signalRoom(env, userId).fetch(`https://signal/internal/limit?${q}`, { method: "POST" });
    return ((await res.json()) as { ok?: boolean }).ok !== false;
  } catch (err) {
    console.error("user rate limit failed", err instanceof Error ? err.message : err);
    return true;
  }
}

export async function notifyHostRemoved(env: AppEnv, userId: string, hostId: string): Promise<void> {
  try {
    await signalRoom(env, userId).fetch(`https://signal/internal/host-removed?hostId=${encodeURIComponent(hostId)}`, { method: "POST" });
  } catch (err) {
    console.error("signal host-removed failed", err instanceof Error ? err.message : err);
  }
}

/** Tells the user's hosts (and phones) that a sign-in family was revoked. */
export async function notifyFamiliesRevoked(env: AppEnv, userId: string, families: string[], closePhones = true): Promise<void> {
  if (families.length === 0) return;
  try {
    await signalRoom(env, userId).fetch("https://signal/internal/revoked", { method: "POST", body: JSON.stringify({ families, closePhones }) });
  } catch (err) {
    console.error("signal revoked failed", err instanceof Error ? err.message : err);
  }
}

export async function notifyUserDeleted(env: AppEnv, userId: string): Promise<void> {
  try {
    await signalRoom(env, userId).fetch("https://signal/internal/close-all", { method: "POST" });
  } catch (err) {
    console.error("signal close-all failed", err instanceof Error ? err.message : err);
  }
}
