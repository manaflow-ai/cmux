// The CodeRouter page's state: a projection of the Mac host's accounts service
// (`cmux.coderouter.status`, `.detect`) plus the host actions it runs. It works signed out:
// detection is local and presence-only, so the page lists this Mac's providers without a cmux
// account. No change stream exists yet, so the page re-reads after its own actions, on a
// reconnect and on Refresh; it never polls.
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import {
  CodeRouterActions,
  CodeRouterOps,
  UNAVAILABLE_CODES,
  type CodeRouterStatus,
  type DetectResult,
  type LinkedAccount,
  type ProviderRow,
} from "./types";

export type Connection = "connecting" | "connected" | "disconnected";

export interface CodeRouterSnapshot {
  connection: Connection;
  loading: boolean;
  status?: CodeRouterStatus;
  providers: ProviderRow[];
  /** Every account CodeRouter holds, from the provider rows (empty signed out). */
  linked: LinkedAccount[];
  /** API keys: no op yet, so always "unavailable" until `coderouter.keys.list` exists. */
  keys: "unavailable";
  error?: string;
}

export class CodeRouterStore {
  private snapshot: CodeRouterSnapshot;
  private readonly listeners = new Set<() => void>();
  private unpage?: () => void;
  private starting?: Promise<void>;
  private generation = 0;

  constructor(private readonly client: PageClient | null) {
    this.snapshot = {
      connection: client ? "connecting" : "disconnected",
      loading: client !== null,
      providers: [],
      linked: [],
      keys: "unavailable",
    };
  }

  getSnapshot = (): CodeRouterSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Follows the host link and loads the first view. Idempotent: every caller awaits one start. */
  start(): Promise<void> {
    if (!this.client) return Promise.resolve();
    this.starting ??= this.begin();
    return this.starting;
  }

  private async begin(): Promise<void> {
    if (!this.client) return;
    try {
      this.unpage = await subscribePageStreams(this.client, {
        onConnection: (connected) => {
          if (!connected) this.set({ connection: "disconnected", loading: false });
          else if (this.snapshot.connection === "disconnected") void this.reload();
        },
      });
    } catch (error) {
      this.set(failure(error));
    }
    await this.reload();
  }

  stop(): void {
    this.unpage?.();
    this.unpage = undefined;
    this.starting = undefined;
  }

  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const [status, detect] = await Promise.all([
        this.client.call<CodeRouterStatus>(CodeRouterOps.status, {}),
        this.client.call<DetectResult>(CodeRouterOps.detect, {}).catch((error: unknown) => {
          if (isPageError(error) && UNAVAILABLE_CODES.has(error.code)) return { providers: [] };
          throw error;
        }),
      ]);
      if (generation !== this.generation) return;
      const providers = detect.providers ?? [];
      this.set({
        connection: "connected",
        loading: false,
        status,
        providers,
        linked: status.signed_in ? providers.flatMap((row) => row.linked ?? []) : [],
        error: undefined,
      });
    } catch (error) {
      if (generation === this.generation) this.set({ loading: false, ...failure(error) });
    }
  }

  signIn(): Promise<void> {
    return this.run(CodeRouterActions.signIn, {});
  }

  connect(provider: string): Promise<void> {
    return this.run(CodeRouterActions.connect, { provider });
  }

  reauthenticate(provider: string): Promise<void> {
    return this.run(CodeRouterActions.reauthenticate, { provider });
  }

  refresh(): Promise<void> {
    return this.run(CodeRouterActions.refresh, {});
  }

  /** Runs a host action as the user (its own sheets and prompts apply), then re-reads. */
  private async run(action: string, args: Record<string, unknown>): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(CodeRouterOps.actionRun, { action, args });
    } catch (error) {
      if (!(isPageError(error) && error.code === "cmux.page.cancelled")) this.set(failure(error));
      return;
    }
    await this.reload();
  }

  private set(patch: Partial<CodeRouterSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function failure(error: unknown): Partial<CodeRouterSnapshot> {
  const message = error instanceof Error ? error.message : String(error);
  if (isPageError(error) && error.code === LINK_CLOSED) return { connection: "disconnected", error: message };
  return { error: message };
}
