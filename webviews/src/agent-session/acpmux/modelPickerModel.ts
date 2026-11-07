import { knownMark } from "../shared/AgentMark";
import { agentName } from "./agents";
import { type ModelPickerProps } from "./modelPickerLayout";

export type HarnessChoice = {
  id: string;
  ids: string[];
  name: string;
  family?: string;
  models: {
    id: string;
    name?: string;
    shortName?: string;
    family?: string;
    unavailable?: string;
    efforts?: string[];
    effortsDeclared?: boolean;
    defaultEffort?: string;
    fast?: boolean;
    inlineFast?: boolean;
    release?: string;
  }[];
  unavailable?: string;
  acpmuxHarness?: string;
  pickable: boolean;
  /** A catalog harness this machine does not have: its tab lists, its models cannot start. */
  notInstalled?: boolean;
  /** A profile from the chat's folder and its state. */
  folder?: ModelPickerProps["catalog"][number]["folder"];
  /** The brand the row's mark draws (a folder profile's icon or family, else its id). */
  mark?: string;
  /** The curated models listed first (topModels/); the rest fold under More models. */
  top?: readonly string[];
};

/// The harness the picker's face draws when the chat names none: its first installed, pickable
/// harness (a bundled catalog harness acpmux does not have is not one), as `current` below picks it.
/// The composer's other chips and the footer's harness item draw the same one (ComposerPickers).
export function pickerFaceHarness(catalog: ModelPickerProps["catalog"]): string | undefined {
  return uniqueHarnesses(catalog).find((entry) => !entry.notInstalled)?.id;
}

// Catalog models can be backed by a lazy native catalog getter. The closed chip needs only
// harness metadata; materialize a group's models when a menu actually asks for them.
export function uniqueHarnesses(catalog: ModelPickerProps["catalog"]): HarnessChoice[] {
  const profiles: HarnessChoice[] = catalog
    .filter((entry) => entry.folder)
    .map((entry) => ({
      id: entry.id,
      ids: [entry.id],
      name: entry.name,
      ...(entry.family ? { family: entry.family } : {}),
      get models() {
        return entry.models;
      },
      unavailable: entry.unavailable,
      acpmuxHarness: entry.id,
      pickable: entry.pickable !== false,
      folder: entry.folder,
      mark: knownMark(entry.icon, entry.family, entry.id),
    }));
  // Terminal and unknown harnesses are routing entries, not installed choices. Every harness the
  // catalog names lists, installed or not, the ones this machine has first (Leo 2026-10-26: "show
  // all harnesses, all models (pi, opencode, prime intellect, etc…)").
  const result: HarnessChoice[] = [];
  const byName = new Map<string, { choice: HarnessChoice; sources: ModelPickerProps["catalog"] }>();
  const ordered = [...catalog.filter((entry) => !entry.notInstalled), ...catalog.filter((entry) => entry.notInstalled)];
  for (const entry of ordered) {
    if (entry.folder || (entry.pickable === false && !entry.notInstalled)) continue;
    const name = agentName(entry.id, entry.name);
    const existing = byName.get(name);
    // An installed harness of the same name already stands for it.
    if (existing && entry.notInstalled) continue;
    if (!existing) {
      const sources = [entry];
      let models: HarnessChoice["models"] | undefined;
      const next: HarnessChoice = {
        id: entry.id,
        ids: [entry.id],
        name,
        ...(entry.family ? { family: entry.family } : {}),
        get models() {
          if (!models) {
            models = [...sources[0]!.models];
            for (const source of sources.slice(1)) {
              const known = new Set(models.map((model) => model.id));
              for (const model of source.models) if (!known.has(model.id)) models.push(model);
            }
          }
          return models;
        },
        unavailable: entry.unavailable,
        acpmuxHarness: entry.id,
        pickable: true,
        ...(entry.notInstalled ? { notInstalled: true } : {}),
        ...(entry.top ? { top: entry.top } : {}),
      };
      result.push(next);
      byName.set(name, { choice: next, sources });
      continue;
    }
    existing.sources.push(entry);
    existing.choice.ids.push(entry.id);
    existing.choice.family ??= entry.family;
    existing.choice.unavailable ??= entry.unavailable;
    existing.choice.top ??= entry.top;
  }
  return [...result, ...profiles];
}

/** A model name as the chip shows it, without the vendor its mark already draws ("Claude Opus 5.5"
 * under Claude's mark reads "Opus 5.5"; Leo 2026-10-13: the footer "tells too much"). Only Claude's
 * names lead with a vendor word that says nothing else ("Gemini 2.5 Pro" would read as a bare
 * number), and another harness's mark (a gateway's) does not say the vendor. The title keeps the
 * full name. */
export function withoutVendor(name: string, mark?: string): string {
  if (!mark?.toLowerCase().startsWith("claude")) return name;
  return name.replace(/^Claude\s+(?=\S)/, "");
}
