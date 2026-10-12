import type { EntryState } from "../entryStore";

export const EXPERIMENTAL_AREA = "Experimental";
const AREAS = ["Agent pane", "New Tab", "Pages", "Home and Chief", "Settings", "Native"];
const FAILED_AREA = "Failed to load";
const LOADING_AREA = "Loading";

/** One ordering for sidebar rows and keyboard navigation, including loads retaining their last entry. */
export function sidebarGroups(states: readonly EntryState[]): { area: string; states: EntryState[] }[] {
  const known = (state: EntryState) => state.entry ?? state.lastGood;
  const areaOf = (state: EntryState) => {
    const entry = known(state);
    return entry?.experimental === true
      ? EXPERIMENTAL_AREA
      : (entry?.area ?? (state.status === "error" ? FAILED_AREA : LOADING_AREA));
  };
  const extras = [...new Set(states.map(areaOf))].filter((area) => !AREAS.includes(area) && area !== EXPERIMENTAL_AREA);
  const areas = [
    ...[FAILED_AREA, LOADING_AREA].filter((area) => extras.includes(area)),
    ...AREAS,
    ...extras.filter((area) => area !== FAILED_AREA && area !== LOADING_AREA).sort(),
    EXPERIMENTAL_AREA,
  ];
  return areas.map((area) => ({
    area,
    states: states
      .filter((state) => areaOf(state) === area)
      .sort((a, b) => (known(a)?.title ?? a.path).localeCompare(known(b)?.title ?? b.path)),
  }));
}
