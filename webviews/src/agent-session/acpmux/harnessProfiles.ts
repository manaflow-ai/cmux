import type { AcpmuxSnapshot } from "./model";

// What each harness's sessions last reported about themselves (model, permission modes, config
// options), kept per viewer. A harness switch draws the target harness's composer from it in the
// same frame as the pick, before acpmux has started that harness; the session's own summary
// replaces it once the session attaches. In the app the pane's web view has a non-persistent
// data store, so profiles last one app session; the first switch to a harness after a launch
// draws the catalog's first model until its session reports. Storage can be missing or blocked: then the profiles
// live for this page only.

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

export type HarnessProfile = {
  harness: string;
  /// The model a session acpmux just started on this harness reported, before any prompt.
  startModel?: string;
  /// The model the harness's last attached session ran.
  model?: string;
  /// acpmux's family for the harness, which names its asking mode (`startMode`).
  family?: string;
  /// The mode a session acpmux just started on this harness reported, and when: acpmux chose it
  /// (hub/start_mode.rs). `modes.currentModeId` is only the last attached chat's mode.
  startMode?: string;
  startedAt?: number;
  modes?: Summary["modes"];
  configOptions?: Summary["configOptions"];
  promptCapabilities?: Summary["promptCapabilities"];
};

const PROFILES_KEY = "cmux.acpmux.harnessProfiles.v1";
/// The level of the person's latest mode pick in a live chat, and when.
const PICK_KEY = "cmux.acpmux.modePick.v1";

/// A mode pick's level, as acpmux saves it (config.json `lastPermissionMode`, hub/start_mode.rs).
type Level = "fullAccess" | "standard" | "ask";
type Pick = { level: Level; at: number };

// acpmux's mode tables (hub/start_mode.rs, web_modes.rs `ASKING_MODES`), mirrored to predict the
// mode it starts a new chat in.
const FULL_ACCESS_MODES = ["bypassPermissions", "agent-full-access", "full-access", "yolo"];
const ASKING_MODES: Record<string, string[]> = { claude: ["default", "plan"] };
const NARROW_MODES = ["ask", "read-only"];
/// A toggle, never saved as a pick.
const TOGGLE_MODES = ["plan"];

function levelOf(mode: string, family: string): Level {
  if (FULL_ACCESS_MODES.includes(mode)) return "fullAccess";
  if (ASKING_MODES[family]?.includes(mode) || NARROW_MODES.includes(mode)) return "ask";
  return "standard";
}

/// The mode `level` gives a harness of `family` offering `offered`; none for `standard` (the
/// harness's own start mode, which the pane cannot know) or a harness with no such mode.
function modeFor(level: Level, family: string, offered: string[]): string | undefined {
  const ids =
    level === "fullAccess" ? FULL_ACCESS_MODES : level === "ask" ? [...(ASKING_MODES[family] ?? []), "ask"] : [];
  return ids.find((id) => offered.includes(id));
}

export class HarnessProfiles {
  private profiles: Map<string, HarnessProfile> | undefined;
  /// The stored text `profiles` was read from or written as: another pane's write reloads them.
  private saved: string | undefined;
  constructor(private readonly storage: () => Storage | undefined = defaultStorage) {}

  get(harness: string | undefined): HarnessProfile | undefined {
    return harness ? this.load().get(harness) : undefined;
  }

  /// Records what an attached session reports. `started` marks a session acpmux just started
  /// for a switch, whose model is the one a new chat on that harness starts on.
  observe(summary: AcpmuxSnapshot["summary"], started = false): void {
    if (!summary?.harness || !summary.sessionId) return;
    const profiles = this.load();
    const before = profiles.get(summary.harness);
    const next: HarnessProfile = {
      harness: summary.harness,
      startModel: started && summary.model ? summary.model : before?.startModel,
      model: summary.model ?? before?.model,
      family: summary.family ?? before?.family,
      ...(started && summary.modes?.currentModeId
        ? { startMode: summary.modes.currentModeId, startedAt: Date.now() }
        : { startMode: before?.startMode, startedAt: before?.startedAt }),
      modes: summary.modes ?? before?.modes,
      configOptions: summary.configOptions?.length ? summary.configOptions : before?.configOptions,
      promptCapabilities: summary.promptCapabilities ?? before?.promptCapabilities,
    };
    profiles.set(summary.harness, next);
    this.save();
  }

  /// A mode the person picked in a live chat on `harness` and acpmux took: acpmux starts every
  /// new chat, on any harness, in its level (hub/start_mode.rs `note_mode_pick`). Plan is a toggle.
  picked(harness: string | undefined, mode: string): void {
    if (!harness || !mode || TOGGLE_MODES.includes(mode)) return;
    const pick: Pick = { level: levelOf(mode, this.get(harness)?.family ?? harness), at: Date.now() };
    try {
      this.storage()?.setItem(PICK_KEY, JSON.stringify(pick));
    } catch {
      // Blocked storage: new chats predict from what acpmux started last.
    }
    this.pick = pick;
  }

  /// The mode acpmux will start a new chat on `harness` in: the latest pick's level when newer
  /// than the harness's last started chat, else the mode that chat started in. None when the
  /// pane has seen neither, or the level leaves the harness its own mode: no guess over a lie.
  startMode(harness: string | undefined): string | undefined {
    const profile = this.get(harness);
    if (!harness || !profile) return undefined;
    const offered = profile.modes?.availableModes.map((mode) => mode.id) ?? [];
    const pick = this.loadPick();
    const mode =
      pick && pick.at > (profile.startedAt ?? 0)
        ? modeFor(pick.level, profile.family ?? harness, offered)
        : profile.startMode;
    return mode && offered.includes(mode) ? mode : undefined;
  }

  private pick: Pick | undefined;

  private loadPick(): Pick | undefined {
    try {
      const value = JSON.parse(this.storage()?.getItem(PICK_KEY) ?? "null") as Pick | null;
      if (value && typeof value.at === "number" && ["fullAccess", "standard", "ask"].includes(value.level))
        this.pick = value;
    } catch {
      // Unreadable: the pick this page made, if any.
    }
    return this.pick;
  }

  private load(): Map<string, HarnessProfile> {
    let text: string | undefined;
    try {
      text = this.storage()?.getItem(PROFILES_KEY) ?? undefined;
    } catch {
      text = undefined;
    }
    if (this.profiles && (text === undefined || text === this.saved)) return this.profiles;
    this.profiles = new Map();
    this.saved = text;
    try {
      const value: unknown = JSON.parse(text ?? "[]");
      if (Array.isArray(value))
        for (const entry of value as HarnessProfile[])
          if (typeof entry?.harness === "string") this.profiles.set(entry.harness, entry);
    } catch {
      // A broken entry is dropped; the next observation writes a good one.
    }
    return this.profiles;
  }

  private save(): void {
    const text = JSON.stringify([...this.load().values()]);
    if (text === this.saved) return;
    this.saved = text;
    try {
      this.storage()?.setItem(PROFILES_KEY, text);
    } catch {
      // Private windows and blocked storage keep the profiles for this page only.
    }
  }
}

function defaultStorage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

/// The pane's profiles, shared by the switch overlay and the client listener that feeds them.
export const harnessProfiles = new HarnessProfiles();
