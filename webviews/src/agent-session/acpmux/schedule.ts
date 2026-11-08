/// A chat's scheduled prompt, cmux's own `/loop` for every harness (acpmux
/// `prompt_schedule.rs`): what the daemon's `_meta.schedule` and the chat's detail carry, and
/// what `/loop` asks for.

export type ScheduleTrigger = { kind: "every"; minutes: number } | { kind: "at"; at: number } | { kind: "idle" };

export type ChatSchedule = {
  id: string;
  prompt: string;
  trigger: ScheduleTrigger;
  maxRuns?: number;
  until?: number;
  runs: number;
  nextRunAt?: number;
  paused: boolean;
};

/// What `_acpmux/schedule/set` takes.
export type ScheduleRequest = {
  prompt: string;
  everyMinutes?: number;
  at?: number;
  idle?: true;
  maxRuns?: number;
  until?: number;
};

const count = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;

/// The daemon's schedule, or undefined for none or a malformed one.
export function chatSchedule(value: unknown): ChatSchedule | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  if (typeof raw.id !== "string" || typeof raw.prompt !== "string") return undefined;
  const t = raw.trigger as Record<string, unknown> | undefined;
  let trigger: ScheduleTrigger;
  if (t?.kind === "every" && count(t.minutes)) trigger = { kind: "every", minutes: t.minutes as number };
  else if (t?.kind === "at" && count(t.at)) trigger = { kind: "at", at: t.at as number };
  else if (t?.kind === "idle") trigger = { kind: "idle" };
  else return undefined;
  return {
    id: raw.id,
    prompt: raw.prompt,
    trigger,
    maxRuns: count(raw.maxRuns),
    until: count(raw.until),
    runs: count(raw.runs) ?? 0,
    nextRunAt: count(raw.nextRunAt),
    paused: raw.paused === true,
  };
}

/// What `/loop ARGS` asks for: a new schedule, a change to the chat's, or undefined when the
/// arguments say neither (the composer shows its usage).
export type LoopCommand = { kind: "set"; request: ScheduleRequest } | { kind: "pause" | "resume" | "stop" };

const UNIT_MINUTES: Record<string, number> = {
  m: 1,
  min: 1,
  mins: 1,
  minute: 1,
  minutes: 1,
  h: 60,
  hr: 60,
  hrs: 60,
  hour: 60,
  hours: 60,
  d: 1440,
  day: 1440,
  days: 1440,
};

/// `5m`, `90min`, `2h`, `1d`: minutes.
function interval(word: string): number | undefined {
  const match = /^(\d+)([a-z]+)$/.exec(word.toLowerCase());
  const unit = match && UNIT_MINUTES[match[2]];
  return match && unit ? Number(match[1]) * unit : undefined;
}

/// `9:30`, `14:05`, `9pm`, `9:30am`: the next such time after `now`, as epoch ms.
function clockTime(word: string, now: Date): number | undefined {
  const match = /^(\d{1,2})(?::(\d{2}))?(am|pm)?$/.exec(word.toLowerCase());
  if (!match || (match[2] === undefined && match[3] === undefined)) return undefined;
  let hours = Number(match[1]);
  const minutes = Number(match[2] ?? 0);
  if (match[3]) {
    if (hours < 1 || hours > 12) return undefined;
    hours = (hours % 12) + (match[3] === "pm" ? 12 : 0);
  }
  if (hours > 23 || minutes > 59) return undefined;
  const at = new Date(now);
  at.setHours(hours, minutes, 0, 0);
  if (at.getTime() <= now.getTime()) at.setDate(at.getDate() + 1);
  return at.getTime();
}

/// Reads `/loop`'s arguments: `5m <prompt>`, `idle <prompt>` or `at 9:30 <prompt>`, each with an
/// optional `x<N>` (at most N runs) and `until <time>` before the prompt; or `pause`, `resume`,
/// `stop`. The prompt is kept as typed after those words, its lines and indentation included.
export function parseLoop(args: string | undefined, now: Date = new Date()): LoopCommand | undefined {
  let rest = (args ?? "").trim();
  const bare = rest.toLowerCase();
  if (bare === "pause" || bare === "resume") return { kind: bare };
  if (bare === "stop" || bare === "off" || bare === "cancel") return { kind: "stop" };
  /// The next word, and what follows it (leading whitespace dropped).
  const peek = (): [string, string] | undefined => {
    const match = /^(\S+)\s*([\s\S]*)$/.exec(rest);
    return match ? [match[1].toLowerCase(), match[2]] : undefined;
  };
  const request: Omit<ScheduleRequest, "prompt"> = {};
  const first = peek();
  if (!first) return undefined;
  rest = first[1];
  const every = interval(first[0]);
  if (every !== undefined) request.everyMinutes = every;
  else if (first[0] === "idle") request.idle = true;
  else if (first[0] === "at") {
    const time = peek();
    const at = time && clockTime(time[0], now);
    if (!time || !at) return undefined;
    rest = time[1];
    request.at = at;
  } else return undefined;
  for (;;) {
    const next = peek();
    const runs = next && /^x(\d+)$/.exec(next[0]);
    if (next && runs) {
      request.maxRuns = Number(runs[1]);
      rest = next[1];
      continue;
    }
    if (next?.[0] === "until") {
      rest = next[1];
      const time = peek();
      const until = time && clockTime(time[0], now);
      if (!time || !until) return undefined;
      request.until = until;
      rest = time[1];
      continue;
    }
    break;
  }
  const prompt = rest.trimEnd();
  if (!prompt || request.maxRuns === 0 || request.everyMinutes === 0) return undefined;
  return { kind: "set", request: { prompt, ...request } };
}
