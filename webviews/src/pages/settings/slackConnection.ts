import type { SettingsClient } from "./ops";

export type SlackTeam = { slackTeamId: string; name: string; cmuxTeamId: string };
export type SlackConnection = { connected: boolean; teams: SlackTeam[] };
export type SlackState = {
  phase: "loading" | "ready" | "connecting" | "awaiting" | "disconnecting";
  teams: SlackTeam[];
  error: "failed" | "signIn" | "unavailable" | null;
  confirmed: boolean;
};

function isSlackTeam(value: unknown): value is SlackTeam {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const team = value as Record<string, unknown>;
  return (["slackTeamId", "name", "cmuxTeamId"] as const).every(
    (key) => typeof team[key] === "string" && team[key].trim().length > 0,
  );
}

/** Only the native Cloud client sees the bearer. No credential or install URL is persisted. */
export class SlackConnectionController {
  private state: SlackState = { phase: "loading", teams: [], error: null, confirmed: false };
  private listeners = new Set<() => void>();
  private revision = 0;
  private disposed = false;
  private refreshAfterMutation = false;
  private confirmationRequested = false;

  constructor(private readonly client: Pick<SettingsClient, "call">) {}

  getSnapshot = (): SlackState => this.state;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  private set(patch: Partial<SlackState>): void {
    if (this.disposed) return;
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }

  private fail(error: unknown): void {
    const code = (error as { code?: string } | null)?.code ?? "";
    this.set({
      phase: "ready",
      error: /unauthorized|signed_out|not_signed_in|http_401|authentication/.test(code)
        ? "signIn"
        : /not_found|not_configured|unavailable|http_404|http_501/.test(code)
          ? "unavailable"
          : "failed",
    });
  }

  async refresh(confirm = false): Promise<void> {
    if (this.disposed) return;
    this.confirmationRequested ||= confirm;
    if (this.state.phase === "connecting" || this.state.phase === "disconnecting") {
      this.refreshAfterMutation ||= confirm;
      return;
    }
    const revision = ++this.revision;
    try {
      const result = await this.client.call<SlackConnection>("cmux.settings.slack.request", { method: "GET" });
      if (this.disposed || revision !== this.revision) return;
      if (
        !Array.isArray(result.teams) ||
        !result.teams.every(isSlackTeam) ||
        typeof result.connected !== "boolean"
      ) {
        throw new Error("invalid response");
      }
      this.set({
        phase: "ready",
        teams: result.connected ? result.teams : [],
        error: null,
        confirmed: result.connected && (this.confirmationRequested || this.state.phase === "awaiting"),
      });
      this.confirmationRequested = false;
    } catch (error) {
      if (revision === this.revision) this.fail(error);
    }
  }

  async connect(): Promise<void> {
    if (this.disposed || ["connecting", "disconnecting", "awaiting"].includes(this.state.phase)) return;
    const revision = ++this.revision;
    this.set({ phase: "connecting", error: null, confirmed: false });
    try {
      const { url } = await this.client.call<{ url: string }>("cmux.settings.slack.request", { method: "POST" });
      if (this.disposed || revision !== this.revision) return;
      // The platform may return its own browser hand-off URL (to establish the OAuth cookie).
      const parsed = new URL(url);
      if (parsed.protocol !== "https:" || parsed.username || parsed.password) throw new Error("invalid URL");
      await this.client.call("cmux.settings.slack.open", { url });
      if (this.disposed || revision !== this.revision) return;
      this.set({ phase: "awaiting" });
    } catch (error) {
      if (revision === this.revision) this.fail(error);
    } finally {
      if (this.refreshAfterMutation) {
        this.refreshAfterMutation = false;
        await this.refresh(true);
      }
    }
  }

  async disconnect(): Promise<void> {
    if (this.disposed || this.state.phase !== "ready" || !this.state.teams.length) return;
    const revision = ++this.revision;
    this.set({ phase: "disconnecting", error: null, confirmed: false });
    try {
      await this.client.call("cmux.settings.slack.request", { method: "DELETE" });
      if (this.disposed || revision !== this.revision) return;
      this.set({ phase: "ready", teams: [] });
      await this.refresh();
    } catch (error) {
      if (revision === this.revision) this.fail(error);
    } finally {
      this.refreshAfterMutation = false;
    }
  }

  dispose(): void {
    this.disposed = true;
    this.revision++;
    this.listeners.clear();
  }
}
