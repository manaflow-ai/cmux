// RFD 0123's Slack awake meter, the Settings side: the shape `GET /v1/chiefs/<agent>/slack-awake`
// answers (cmux-api, cmux#57375) and the pure reads the card draws from it. The meter, the cap and
// the allowance's bounds are the server's; this file only picks today's rows and words seconds.

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

/** `2 h`, `1 h 20 min`, `45 min`, `under 1 min`, `0 min`. */
export function awakeDuration(seconds: number): string {
  if (seconds <= 0) return "0 min";
  if (seconds < 60) return "under 1 min";
  const minutes = Math.round(seconds / 60);
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m} min`;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

/** The allowance choices the presets variant offers, in seconds (0: non-owners never wake it). */
export const ALLOWANCE_PRESETS: readonly number[] = [0, 1800, 3600, 7200, 14400, 28800];
