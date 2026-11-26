// RFD 0123's Slack awake meter, the Settings side: the shape `GET /v1/chiefs/<agent>/slack-awake`
// answers (cmux-api, cmux#57375) and the pure reads the card draws from it. The meter, the cap and
// the allowance's bounds are the server's; this file only picks today's rows, words seconds, and
// holds the controller that reads and sets the allowance through `cmux.settings.slack.awake`.
import type { SettingsClient } from "./ops";
import { t } from "./strings";

/** One sender's awake time on one UTC day, as the API answers it. */
export interface SlackSpendRow {
  readonly slack_team: string;
  readonly slack_user: string;
  readonly sender_is_owner: boolean;
  /** UTC day, `YYYY-MM-DD`. */
  readonly day: string;
  readonly seconds: number;
  readonly turns: number;
}

/** `GET /v1/chiefs/<agent>/slack-awake`'s value. */
export interface SlackAwake {
  /** Each non-owner's daily allowance: the owner's setting, or the default when unset. */
  readonly allowance_seconds: number;
  readonly default_seconds: number;
  readonly max_seconds: number;
  readonly days: number;
  readonly senders: readonly SlackSpendRow[];
  /** Slack names by `slack_user`, for senders the server has one for (cmux#59097). */
  readonly names?: SlackNames;
}

/** Slack user ids the card can show a name for; unknown ids show the id. */
export type SlackNames = Readonly<Record<string, string>>;

export interface SpentRow {
  readonly user: string;
  readonly name: string;
  readonly owner: boolean;
  readonly seconds: number;
  readonly turns: number;
  /** For a non-owner, the share of the allowance used today, 0..1; null for the owner. */
  readonly used: number | null;
}

/** Today's senders, most awake time first; the owner's time counts but is never capped. */
export function spentToday(awake: SlackAwake, today: string, names: SlackNames = {}): SpentRow[] {
  const byUser = new Map<string, SpentRow>();
  for (const row of awake.senders) {
    if (row.day !== today) continue;
    const key = `${row.slack_team}/${row.slack_user}`;
    const prev = byUser.get(key);
    const seconds = (prev?.seconds ?? 0) + row.seconds;
    const owner = (prev?.owner ?? false) || row.sender_is_owner;
    byUser.set(key, {
      user: row.slack_user,
      name: names[row.slack_user] ?? row.slack_user,
      owner,
      seconds,
      turns: (prev?.turns ?? 0) + row.turns,
      used: owner ? null : awake.allowance_seconds > 0 ? Math.min(seconds / awake.allowance_seconds, 1) : 1,
    });
  }
  return [...byUser.values()].sort((a, b) => b.seconds - a.seconds || a.name.localeCompare(b.name));
}

/** `2 h`, `1 h 20 min`, `45 min`, `under 1 min`, `0 min`, in the page's language. */
export function awakeDuration(seconds: number): string {
  if (seconds <= 0) return t("settingsPage.slack.awake.minutes", 0);
  if (seconds < 60) return t("settingsPage.slack.awake.underMinute");
  const minutes = Math.round(seconds / 60);
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return t("settingsPage.slack.awake.minutes", m);
  return m === 0 ? t("settingsPage.slack.awake.hours", h) : t("settingsPage.slack.awake.hoursMinutes", h, m);
}

/** The allowance choices the presets variant offers, in seconds (0: non-owners never wake it). */
export const ALLOWANCE_PRESETS: readonly number[] = [0, 1800, 3600, 7200, 14400, 28800];

export type SlackAwakeState = {
  phase: "loading" | "ready" | "saving";
  awake: SlackAwake | null;
  error: "failed" | "saveFailed" | "noChief" | null;
};

const isCount = (value: unknown): value is number => typeof value === "number" && Number.isInteger(value) && value >= 0;

function isSpendRow(value: unknown): value is SlackSpendRow {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  return (
    typeof row.slack_team === "string" &&
    typeof row.slack_user === "string" &&
    typeof row.sender_is_owner === "boolean" &&
    typeof row.day === "string" &&
    /^\d{4}-\d{2}-\d{2}$/.test(row.day) &&
    isCount(row.seconds) &&
    isCount(row.turns)
  );
}

/** The API's value, or null when any field is off (the card then shows the read failure). */
export function parseSlackAwake(value: unknown): SlackAwake | null {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  if (![v.allowance_seconds, v.default_seconds, v.max_seconds, v.days].every(isCount)) return null;
  if (!Array.isArray(v.senders) || !v.senders.every(isSpendRow)) return null;
  if (v.names !== undefined) {
    if (v.names === null || typeof v.names !== "object" || Array.isArray(v.names)) return null;
    if (!Object.values(v.names).every((name) => typeof name === "string")) return null;
  }
  return v as unknown as SlackAwake;
}

/**
 * Reads and sets the default Chief's Slack allowance through the native relay (the Stack session
 * stays native). `{}` reads; `{allowance_seconds}` sets seconds, or null for the default.
 */
export class SlackAwakeController {
  private state: SlackAwakeState = { phase: "loading", awake: null, error: null };
  private listeners = new Set<() => void>();
  private revision = 0;
  private disposed = false;

  constructor(private readonly client: Pick<SettingsClient, "call">) {}

  getSnapshot = (): SlackAwakeState => this.state;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  dispose(): void {
    this.disposed = true;
    this.listeners.clear();
  }

  private set(patch: Partial<SlackAwakeState>): void {
    if (this.disposed) return;
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }

  private async send(params: Record<string, unknown>, onFail: "failed" | "saveFailed"): Promise<void> {
    const revision = ++this.revision;
    try {
      const awake = parseSlackAwake(await this.client.call<unknown>("cmux.settings.slack.awake", params));
      if (this.disposed || revision !== this.revision) return;
      if (!awake) throw new Error("invalid response");
      this.set({ phase: "ready", awake, error: null });
    } catch (error) {
      if (this.disposed || revision !== this.revision) return;
      const code = (error as { code?: string } | null)?.code ?? "";
      this.set({ phase: "ready", error: /no_chief/.test(code) ? "noChief" : onFail });
    }
  }

  async refresh(): Promise<void> {
    if (this.disposed || this.state.phase === "saving") return;
    await this.send({}, "failed");
  }

  async setAllowance(seconds: number | null): Promise<void> {
    if (this.disposed || this.state.phase === "saving") return;
    this.set({ phase: "saving" });
    await this.send({ allowance_seconds: seconds }, "saveFailed");
  }
}
