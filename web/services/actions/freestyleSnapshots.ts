import { Freestyle } from "freestyle";

export type FreestyleActionSnapshot = {
  readonly id: string;
  readonly name: string;
  readonly createdAt: string;
};

type FreestyleSnapshotRecord = {
  readonly snapshotId?: string;
  readonly id?: string;
  readonly name?: string;
  readonly state?: string;
  readonly status?: string;
  readonly deleted?: boolean;
  readonly failureReason?: string;
  readonly createdAt?: string;
};

type FreestyleSnapshotListResponse = {
  readonly snapshots?: readonly FreestyleSnapshotRecord[] | null;
};

const DEFAULT_TIMEOUT_MS = 60_000;

export async function findFreestyleActionSnapshotByName(
  name: string,
): Promise<FreestyleActionSnapshot | null> {
  const fs = new Freestyle({ fetch: fetchWithTimeout(DEFAULT_TIMEOUT_MS) });
  const response = await fs.fetch(freestyleSnapshotListURL(), { method: "GET" });
  if (!response.ok) {
    throw new Error(`action cache lookup failed: HTTP ${response.status}`);
  }
  const json = await response.json() as FreestyleSnapshotListResponse;
  const matches = (json.snapshots ?? [])
    .filter((snapshot) => snapshot.name === name && snapshot.deleted !== true)
    .sort((a, b) => (b.createdAt ?? "").localeCompare(a.createdAt ?? ""));
  const latest = matches[0];
  if (!latest) return null;
  const state = (latest.state ?? latest.status ?? "").toLowerCase();
  if (["failed", "error"].includes(state)) {
    throw new Error("action cache snapshot is unavailable");
  }
  const id = latest.snapshotId ?? latest.id;
  if (!id || !latest.name || !latest.createdAt) return null;
  return { id, name: latest.name, createdAt: latest.createdAt };
}

function freestyleSnapshotListURL(): string {
  const base = (process.env.FREESTYLE_API_URL ?? "https://api.freestyle.sh").replace(/\/+$/, "");
  const url = new URL("/v1/vms/snapshots", base);
  url.searchParams.set("includeDeleted", "false");
  url.searchParams.set("includeFailed", "true");
  return url.toString();
}

function fetchWithTimeout(timeoutMs: number): typeof fetch {
  return async (input, init) => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
      return await fetch(input, {
        ...(init ?? {}),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timeout);
    }
  };
}
