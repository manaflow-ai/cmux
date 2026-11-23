import type { SettingsClient } from "./ops";

export type SlackTeam = { slackTeamId: string; name: string; cmuxTeamId: string };
export type SlackConnection = { connected: boolean; teams: SlackTeam[] };
export type SlackState = {
  phase: "loading" | "ready" | "connecting" | "awaiting" | "disconnecting";
  teams: SlackTeam[];
  error:
    | "failed"
    | "signIn"
    | "unavailable"
    | "tokenInvalid"
    | "nameInvalid"
    | "rateLimited"
    | "appLimit"
    | "createFailed"
    | null;
  confirmed: boolean;
};

/** What Slack accepts for an app name and for an app configuration token (the platform checks the same). */
export const BOT_NAME_MAX = 35;
export const validBotName = (name: string): boolean =>
  name.length >= 1 && name.length <= BOT_NAME_MAX && name.trim() === name && !/[\p{Cc}<>@#*_~`]/u.test(name);
export const validConfigToken = (token: string): boolean => /^xoxe\.xoxp-[A-Za-z0-9-]{10,1000}$/.test(token);

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
    const known = (
      [
        [/config_token_invalid/, "tokenInvalid"],
        [/rate_limited/, "rateLimited"],
        [/app_limit/, "appLimit"],
        [/app_create_failed/, "createFailed"],
        [/unauthorized|signed_out|not_signed_in|http_401|authentication/, "signIn"],
        [/not_found|not_configured|unavailable|http_404|http_501/, "unavailable"],
      ] as const
    ).find(([pattern]) => pattern.test(code));
    this.set({ phase: "ready", error: known ? known[1] : "failed" });
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
      if (!Array.isArray(result.teams) || !result.teams.every(isSlackTeam) || typeof result.connected !== "boolean") {
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
    await this.handOff(async () => {
      const { url } = await this.client.call<{ url: string }>("cmux.settings.slack.request", { method: "POST" });
      return url;
    });
  }

  /**
   * "Use your own bot name": the platform makes the app from the pasted configuration token (used once; this
   * class never keeps it) and answers with its install link, which opens like the default door's.
   */
  async createOwnBot(name: string, configToken: string): Promise<void> {
    const trimmed = name.trim();
    if (trimmed && !validBotName(trimmed)) return this.set({ error: "nameInvalid" });
    if (!validConfigToken(configToken.trim())) return this.set({ error: "tokenInvalid" });
    await this.handOff(async () => {
      const { installUrl } = await this.client.call<{ installUrl: string }>("cmux.settings.slack.create_app", {
        configToken: configToken.trim(),
        ...(trimmed ? { name: trimmed } : {}),
      });
      return installUrl;
    });
  }

  /** Opens the one-time Slack Allow page the platform returned, then waits for cmux://slack/connected. */
  private async handOff(install: () => Promise<string>): Promise<void> {
    if (this.disposed || ["connecting", "disconnecting", "awaiting"].includes(this.state.phase)) return;
    const revision = ++this.revision;
    this.set({ phase: "connecting", error: null, confirmed: false });
    try {
      const url = await install();
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

  /** Opens Slack's page that shows the configuration token (api.slack.com/apps) in the system browser. */
  async openTokenPage(): Promise<void> {
    try {
      await this.client.call("cmux.settings.slack.open", { url: "https://api.slack.com/apps" });
    } catch (error) {
      this.fail(error);
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
