export type CloudMachine = {
  id: string;
  provider: string;
  status: "provisioning" | "running" | "paused" | "failed" | "destroyed";
  image: string;
  imageVersion: string;
  createdAt: string;
};

export type CloudSession = {
  id: string;
  sessionId: string;
  title: string | null;
  kind: string;
  status: "running" | "detached" | "exited" | "closed";
  attachmentCount: number;
  updatedAt: string;
  lastAttachedAt: string | null;
};

type ApiErrorPayload = {
  message?: unknown;
};

export class CloudPortalApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "CloudPortalApiError";
  }
}

async function portalFetch<T>(input: RequestInfo | URL, init?: RequestInit): Promise<T> {
  const response = await fetch(input, {
    credentials: "same-origin",
    ...init,
    headers: {
      accept: "application/json",
      ...init?.headers,
    },
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => null) as ApiErrorPayload | null;
    throw new CloudPortalApiError(
      response.status,
      typeof payload?.message === "string" ? payload.message : `HTTP ${response.status}`,
    );
  }
  return await response.json() as T;
}

export async function listCloudMachines(): Promise<CloudMachine[]> {
  const response = await portalFetch<{ vms: CloudMachine[] }>("/api/vm");
  return response.vms.filter((machine) => machine.status !== "destroyed");
}

export async function createCloudMachine(): Promise<Omit<CloudMachine, "status">> {
  const idempotencyKey = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
  return await portalFetch<Omit<CloudMachine, "status">>("/api/vm", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "idempotency-key": idempotencyKey,
    },
    body: "{}",
  });
}

export async function deleteCloudMachine(machineId: string): Promise<void> {
  await portalFetch<{ ok: true }>(`/api/vm/${encodeURIComponent(machineId)}`, {
    method: "DELETE",
  });
}

export async function listCloudSessions(machineId: string): Promise<CloudSession[]> {
  const response = await portalFetch<{ sessions: CloudSession[] }>(
    `/api/vm/${encodeURIComponent(machineId)}/sessions`,
  );
  return response.sessions;
}

export function shortMachineId(id: string): string {
  return id.length <= 14 ? id : `${id.slice(0, 8)}…${id.slice(-4)}`;
}
