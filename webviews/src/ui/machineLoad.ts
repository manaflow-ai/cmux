// One machine's load row, as every list of machines draws it (the composer's machine picker and
// Settings > Machines; cmuxterm-hq docs/design/remote-spin-up.md 2.6): its state, cores busy of
// total, free RAM, live chats and placement's verdict. acpmux computes all of it once
// (cmux-tui acpmux placement.rs `load_row`, each `peers[].load` of `_acpmux/status` and
// `_acpmux/peers`); a page only words it, so no two surfaces can show different numbers.

/** Placement's verdict on a machine (`load_row`'s `verdict`). */
export type MachineLoadVerdict = "room" | "busy" | "held" | "connecting" | "offline" | "unknown";

const VERDICTS: ReadonlySet<string> = new Set(["room", "busy", "held", "connecting", "offline", "unknown"]);

/** `peers[].load` as acpmux sends it: each number null when the machine gave no reading of it. */
export type MachineLoad = {
  verdict: MachineLoadVerdict;
  /** The verdict as the CLI says it ("room for 5"), for a surface with no catalog of its own. */
  words: string;
  room: number | null;
  coresBusy: number | null;
  cores: number | null;
  ramFreeBytes: number | null;
  live: number | null;
  offlineMs: number | null;
};

function count(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}

/** A `peers[].load` value, or undefined when it is not one (an older daemon sends none). */
export function machineLoadOf(value: unknown): MachineLoad | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const row = value as Record<string, unknown>;
  if (typeof row.verdict !== "string" || !VERDICTS.has(row.verdict)) return undefined;
  return {
    verdict: row.verdict as MachineLoadVerdict,
    words: typeof row.words === "string" ? row.words : row.verdict,
    room: count(row.room),
    coresBusy: count(row.coresBusy),
    cores: count(row.cores),
    ramFreeBytes: count(row.ramFreeBytes),
    live: count(row.live),
    offlineMs: count(row.offlineMs),
  };
}

/** Each named peer's load row from a `_acpmux/status` or `_acpmux/peers` reply. */
export function machineLoadsFromStatus(status: unknown): Record<string, MachineLoad> {
  const peers = (status as { peers?: unknown } | null | undefined)?.peers;
  const out: Record<string, MachineLoad> = {};
  if (!Array.isArray(peers)) return out;
  for (const peer of peers) {
    const name = (peer as { name?: unknown } | null)?.name;
    const load = machineLoadOf((peer as { load?: unknown } | null)?.load);
    if (typeof name === "string" && name && load) out[name] = load;
  }
  return out;
}

/** The strings a load row is worded with; each surface gives them from its own catalog. */
export type MachineLoadKey =
  | "cores"
  | "free"
  | "chat"
  | "chats"
  | "room"
  | "busy"
  | "held"
  | "connecting"
  | "offline"
  | "offlineFor"
  | "minutes"
  | "hours"
  | "days"
  | "unknown";
/** A string's placeholders: `n`, `busy`, `cores`, `free` or `ago`. */
export type MachineLoadValues = Record<string, string | number>;
export type MachineLoadSay = (key: MachineLoadKey, values?: MachineLoadValues) => string;

/** Free RAM in GB as the row shows it: whole above 10 GB, else one decimal. */
export function freeGB(bytes: number): string {
  const gb = bytes / 1e9;
  return gb >= 10 ? String(Math.round(gb)) : (Math.round(gb * 10) / 10).toString();
}

/** How long a machine has been offline, in the row's words ("2 min", "3 h"); under a minute none. */
function offlineFor(ms: number, say: MachineLoadSay): string | undefined {
  const min = Math.floor(ms / 60_000);
  if (min < 1) return undefined;
  if (min < 60) return say("minutes", { n: min });
  if (min < 1440) return say("hours", { n: Math.floor(min / 60) });
  return say("days", { n: Math.floor(min / 1440) });
}

/** A load row in words: its facts (cores, RAM, chats; none for a machine that is not up) and verdict. */
export function machineLoadText(load: MachineLoad, say: MachineLoadSay): { facts: string[]; verdict: string } {
  const up = load.verdict !== "offline" && load.verdict !== "connecting";
  const facts: string[] = [];
  if (up && load.coresBusy !== null && load.cores !== null) {
    facts.push(say("cores", { busy: load.coresBusy.toFixed(1).replace(/\.0$/, ""), cores: load.cores }));
  }
  if (up && load.ramFreeBytes !== null) facts.push(say("free", { free: freeGB(load.ramFreeBytes) }));
  if (up && load.live !== null) facts.push(load.live === 1 ? say("chat") : say("chats", { n: load.live }));
  let verdict: string;
  switch (load.verdict) {
    case "room":
      verdict = say("room", { n: load.room ?? 0 });
      break;
    case "offline": {
      const ago = load.offlineMs === null ? undefined : offlineFor(load.offlineMs, say);
      verdict = ago ? say("offlineFor", { ago }) : say("offline");
      break;
    }
    default:
      verdict = say(load.verdict);
  }
  return { facts, verdict };
}

/** How often an open list of machines reads their load rows again, the picker's and Settings' alike
 * (environmentPickerModel.ts MACHINES_REFRESH_MS): acpmux sends no peer events. */
export const MACHINE_LOAD_REFRESH_MS = 5_000;
