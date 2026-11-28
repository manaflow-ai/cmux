// l10n-allow-file: gallery and test fixtures (public-safe sample sessions), not shipped UI.
import type { MissionTile, MissionTileKind, MissionTileState, MissionThumb } from "./model";

const KINDS: MissionTileKind[] = ["terminal", "chat", "browser"];
const STATES: MissionTileState[] = ["working", "waiting", "working", "done", "working"];
const MACHINES = ["laptop", "cloud-1", "cloud-2", "studio"];
const TITLES = [
  "Fix flaky sidebar test",
  "Review PR: grid layout",
  "Docs preview",
  "Bench sessions at 200",
  "Upgrade bun",
  "Port settings page",
  "Triage crash report",
  "Build iOS app",
];

/** A stand-in picture: a dark screen with a few text lines, as a terminal or chat snapshot looks. */
function thumb(kind: MissionTileKind, seed: number): MissionThumb {
  const bg = kind === "browser" ? "#f4f4f5" : "#1c1c1f"; // colour-allow: stand-in screenshot pixels, not UI colour
  const ink = kind === "browser" ? "#9a9aa2" : "#5d8c6a"; // colour-allow: stand-in screenshot pixels, not UI colour
  const lines = Array.from({ length: 7 }, (_, i) => {
    const width = 60 + ((seed * 37 + i * 53) % 220);
    return `<rect x="16" y="${20 + i * 22}" width="${width}" height="8" rx="2" fill="${ink}"/>`;
  }).join("");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200"><rect width="320" height="200" fill="${bg}"/>${lines}</svg>`;
  return { src: `data:image/svg+xml,${encodeURIComponent(svg)}`, width: 320, height: 200 };
}

export function fixtureTiles(count: number, options: { thumbs?: boolean } = {}): MissionTile[] {
  const thumbs = options.thumbs ?? true;
  return Array.from({ length: count }, (_, i) => {
    const kind = KINDS[i % KINDS.length]!;
    return {
      id: `s${i}`,
      title: TITLES[i % TITLES.length]!,
      machineName: MACHINES[i % MACHINES.length]!,
      kind,
      state: STATES[i % STATES.length]!,
      age: `${(i % 50) + 1}m`,
      thumb: thumbs ? thumb(kind, i) : null,
    };
  });
}

export const FIXTURE_STRINGS = {
  title: "Mission control",
  working: "Working",
  waiting: "Waiting on you",
  done: "Done",
  noPicture: "No picture yet",
  empty: "No sessions",
};
