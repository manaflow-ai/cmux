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

export async function notifyHostRemoved(env: AppEnv, userId: string, hostId: string): Promise<void> {
  try {
    await signalRoom(env, userId).fetch(`https://signal/internal/host-removed?hostId=${encodeURIComponent(hostId)}`, { method: "POST" });
  } catch (err) {
    console.error("signal host-removed failed", err instanceof Error ? err.message : err);
  }
}

export async function notifyUserDeleted(env: AppEnv, userId: string): Promise<void> {
  try {
    await signalRoom(env, userId).fetch("https://signal/internal/close-all", { method: "POST" });
  } catch (err) {
    console.error("signal close-all failed", err instanceof Error ? err.message : err);
  }
}
