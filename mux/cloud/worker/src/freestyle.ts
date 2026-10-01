// Minimal Freestyle VM client over its REST API (the SDK targets Node).

const API = "https://api.freestyle.sh";

export interface ExecResult {
  stdout: string;
  stderr: string;
  statusCode: number | null;
}

async function call<T>(apiKey: string, method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok)
    throw new Error(
      `freestyle ${method} ${path}: ${response.status} ${(await response.text()).slice(0, 300)}`,
    );
  return (await response.json()) as T;
}

/** The VM with this slug, created (paused when idle, no inbound traffic) if it does not exist. */
export async function ensureVm(
  apiKey: string,
  slug: string,
  displayName: string,
  snapshotId?: string,
): Promise<string> {
  const found = await call<{ vms: { id: string }[] }>(
    apiKey,
    "GET",
    `/v5/vms?slug=${encodeURIComponent(slug)}`,
  );
  if (found.vms[0]) return found.vms[0].id;
  const created = await call<{ id: string }>(apiKey, "POST", "/v5/vms", {
    slug,
    displayName,
    ...(snapshotId ? { snapshotId } : {}),
    // Exec wakes a paused VM in ~0.1 s, so idle pausing costs nothing in latency.
    idleTimeoutSeconds: 300,
    metadata: { mux: "memory" },
    firewall: { rules: [] },
  });
  return created.id;
}

/** Runs a shell command on the VM and waits for it. Throws on a non-zero exit. */
export async function exec(
  apiKey: string,
  vmId: string,
  command: string,
  options: { stdin?: string; env?: Record<string, string>; timeoutMs?: number } = {},
): Promise<string> {
  const result = await call<ExecResult>(
    apiKey,
    "POST",
    `/v5/vms/${encodeURIComponent(vmId)}/exec-await`,
    {
      command,
      timeoutMs: options.timeoutMs ?? 30_000,
      env: options.env,
      stdin: options.stdin === undefined ? undefined : base64(options.stdin),
    },
  );
  if (result.statusCode !== 0) {
    throw new Error(
      `exec failed (${result.statusCode ?? "timeout"}): ${(result.stderr || result.stdout || "").slice(0, 300)}`,
    );
  }
  return result.stdout ?? "";
}

function base64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}
