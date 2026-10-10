/**
 * A coding worker's machine (plans/cmux-next/chief.md step 6): a VM with
 * Claude Code and Codex preinstalled. The runner only needs these three
 * calls, so tests use a fake and the Worker uses Freestyle's REST API.
 */

export interface VmExecResult {
  /** Null when the command hit its timeout. */
  readonly statusCode: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

export interface VmDriver {
  create(options: { readonly label: string; readonly maxRunSeconds: number }): Promise<{ readonly id: string }>;
  exec(
    id: string,
    command: string,
    options: { readonly env?: Record<string, string>; readonly timeoutMs: number },
  ): Promise<VmExecResult>;
  destroy(id: string): Promise<void>;
}

/** Why a coding worker cannot run in this environment. */
export class VmUnavailable extends Error {
  constructor(message: string) {
    super(message);
    this.name = "VmUnavailable";
  }
}

const API = "https://api.freestyle.sh/v5";

/** Longest single exec Freestyle accepts. */
export const EXEC_TIMEOUT_MAX_MS = 300_000;

/**
 * Freestyle over plain fetch (workerd-safe). Without a key every call
 * refuses: dev and staging get no Freestyle key until the non-production
 * account exists (coordinator decision, 2026-10-03).
 */
export class FreestyleDriver implements VmDriver {
  constructor(
    private readonly key: string | undefined,
    private readonly snapshotId: string | undefined,
    private readonly fetcher: typeof fetch = fetch,
  ) {}

  private headers(): Record<string, string> {
    if (!this.key) throw new VmUnavailable("No Freestyle key in this environment, so coding workers cannot start.");
    return { authorization: `Bearer ${this.key}`, "content-type": "application/json" };
  }

  async create(options: { readonly label: string; readonly maxRunSeconds: number }): Promise<{ readonly id: string }> {
    const headers = this.headers();
    if (!this.snapshotId) throw new VmUnavailable("No Freestyle snapshot is configured for coding workers.");
    const response = await this.fetcher(`${API}/vms`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        snapshotId: this.snapshotId,
        idleTimeoutSeconds: 600,
        maxRunTotalSeconds: options.maxRunSeconds,
        automaticRestart: false,
        metadata: { app: "chief-experiment", label: options.label },
        // Freestyle denies all egress by default; the agent needs the public internet.
        firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
      }),
    });
    if (!response.ok) throw new Error(`Freestyle create failed: HTTP ${response.status} ${await response.text()}`);
    const body = (await response.json()) as { id?: string; vmId?: string };
    const id = body.vmId ?? body.id;
    if (!id) throw new Error("Freestyle create returned no VM id.");
    return { id };
  }

  async exec(
    id: string,
    command: string,
    options: { readonly env?: Record<string, string>; readonly timeoutMs: number },
  ): Promise<VmExecResult> {
    const response = await this.fetcher(`${API}/vms/${encodeURIComponent(id)}/exec-await`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        command,
        timeoutMs: Math.min(options.timeoutMs, EXEC_TIMEOUT_MAX_MS),
        linuxUser: "ubuntu",
        ...(options.env ? { env: options.env } : {}),
      }),
    });
    if (!response.ok) throw new Error(`Freestyle exec failed: HTTP ${response.status}`);
    const body = (await response.json()) as { statusCode?: number | null; stdout?: string; stderr?: string };
    return { statusCode: body.statusCode ?? null, stdout: body.stdout ?? "", stderr: body.stderr ?? "" };
  }

  async destroy(id: string): Promise<void> {
    const response = await this.fetcher(`${API}/vms/${encodeURIComponent(id)}`, {
      method: "DELETE",
      headers: this.headers(),
    });
    if (!response.ok && response.status !== 404) throw new Error(`Freestyle delete failed: HTTP ${response.status}`);
  }
}
