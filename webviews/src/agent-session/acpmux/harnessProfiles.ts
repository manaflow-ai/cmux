import type { AcpmuxSnapshot } from "./model";

// What each harness's sessions last reported about themselves (model, permission modes, config
// options), kept per viewer. A harness switch draws the target harness's composer from it in the
// same frame as the pick, before acpmux has started that harness; the session's own summary
// replaces it once the session attaches. Storage can be missing or blocked: then the profiles
// live for this page only.

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

export type HarnessProfile = {
  harness: string;
  /// The model a session acpmux just started on this harness reported, before any prompt.
  startModel?: string;
  /// The model the harness's last attached session ran.
  model?: string;
  modes?: Summary["modes"];
  configOptions?: Summary["configOptions"];
  promptCapabilities?: Summary["promptCapabilities"];
};

const PROFILES_KEY = "cmux.acpmux.harnessProfiles.v1";

export class HarnessProfiles {
  private profiles: Map<string, HarnessProfile> | undefined;
  private saved = "";
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
      modes: summary.modes ?? before?.modes,
      configOptions: summary.configOptions?.length ? summary.configOptions : before?.configOptions,
      promptCapabilities: summary.promptCapabilities ?? before?.promptCapabilities,
    };
    profiles.set(summary.harness, next);
    this.save();
  }

  private load(): Map<string, HarnessProfile> {
    if (this.profiles) return this.profiles;
    this.profiles = new Map();
    try {
      const value: unknown = JSON.parse(this.storage()?.getItem(PROFILES_KEY) ?? "[]");
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
