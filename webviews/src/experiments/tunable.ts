// Tunables: named values a component reads at run time that a person can edit in the gallery,
// for choices an arm list cannot hold (a curve, a length). Experiments (experiment.ts) compare a
// few fixed implementations; a tunable is one implementation with an open value.
//
// A tunable is defined in code next to the component it tunes, with the value that ships. The
// component asks `tunableValue(tunable)` for the value to use. A good value ships by changing
// `defaultValue` in the definition.
//
// The value comes from one place, in this order:
//   1. an override the host installs before the page loads (`globalThis.cmuxTunables`: the
//      gallery's stage frame sets it from its `tune` query key);
//   2. the debug key `cmux.tunables` in localStorage, a JSON object `{ "<id>": "<value>" }`
//      (for dogfood in the app: set it in the web inspector and reload the pane);
//   3. the tunable's `defaultValue`.
// An invalid value anywhere falls through to the next source, so a stale key never breaks a page.
import { formatBezier, parseBezier, type CubicBezier } from "../ui/cubicBezier";
import { EXPERIMENT_ID } from "./experiment";

export type BezierTunable = {
  /** Lower kebab case, unique: `diff-tree-marquee-easing`. */
  id: string;
  title: string;
  /** One or two sentences: what the value changes and what to look for. */
  description: string;
  kind: "cubic-bezier";
  /** The value that ships. */
  defaultValue: CubicBezier;
  /** Named starting points for the editor, besides the CSS keywords. */
  presets?: Record<string, CubicBezier>;
};

export type Tunable = BezierTunable;

export function defineTunable(tunable: Tunable): Tunable {
  return tunable;
}

/** The localStorage debug key. */
export const TUNABLES_STORAGE_KEY = "cmux.tunables";

export type TunableOverrides = Record<string, string>;

declare global {
  // eslint-disable-next-line no-var -- a host-installed global, read once per lookup.
  var cmuxTunables: TunableOverrides | undefined;
}

function storedOverrides(): TunableOverrides {
  try {
    const text = globalThis.localStorage?.getItem(TUNABLES_STORAGE_KEY);
    const parsed: unknown = text ? JSON.parse(text) : undefined;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as TunableOverrides) : {};
  } catch {
    // No storage (a sandboxed page) or a malformed value: no override.
    return {};
  }
}

const parse = (value: unknown) => (typeof value === "string" ? parseBezier(value) : undefined);

/** The value to use: the host override, else the debug key, else the default. */
export function tunableValue(
  tunable: Tunable,
  sources: { overrides?: TunableOverrides; stored?: TunableOverrides } = {},
): CubicBezier {
  const overrides = sources.overrides ?? globalThis.cmuxTunables ?? {};
  return (
    parse(overrides[tunable.id]) ?? parse((sources.stored ?? storedOverrides())[tunable.id]) ?? tunable.defaultValue
  );
}

/** The gallery's `tune` query value: `<id>=<value>` pairs split by `;`. Invalid pairs are dropped. */
export function readTunes(text: string): TunableOverrides {
  const tunes: TunableOverrides = {};
  for (const pair of text.split(";")) {
    const at = pair.indexOf("=");
    const id = pair.slice(0, at);
    const value = parseBezier(pair.slice(at + 1));
    if (at > 0 && EXPERIMENT_ID.test(id) && value) tunes[id] = formatBezier(value);
  }
  return tunes;
}

export function writeTunes(tunes: TunableOverrides): string {
  return Object.keys(tunes)
    .sort()
    .map((id) => `${id}=${tunes[id]}`)
    .join(";");
}

/** Definition problems: ids, defaults the parser accepts, no repeats. */
export function validateTunables(tunables: readonly Tunable[]): string[] {
  const problems: string[] = [];
  const seen = new Set<string>();
  for (const tunable of tunables) {
    if (!EXPERIMENT_ID.test(tunable.id)) problems.push(`${tunable.id}: the id must be lower kebab case`);
    if (seen.has(tunable.id)) problems.push(`${tunable.id}: duplicate tunable id`);
    seen.add(tunable.id);
    if (!parseBezier(formatBezier(tunable.defaultValue)))
      problems.push(`${tunable.id}: the default is not a valid curve`);
    for (const [name, preset] of Object.entries(tunable.presets ?? {}))
      if (!parseBezier(formatBezier(preset))) problems.push(`${tunable.id}: preset ${name} is not a valid curve`);
  }
  return problems;
}
