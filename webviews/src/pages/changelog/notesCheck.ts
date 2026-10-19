import type { ReleaseNotes } from "./types";

export type DefectKind = "duplicate" | "truncated" | "bead" | "internal";

export interface NotesDefect {
  kind: DefectKind;
  where: "notes" | "page (1 nightly)" | "page (10 nightlies)" | "card";
  text: string;
}

export function checkNightlyNotes(_notes: ReleaseNotes, _previous: ReleaseNotes[]): NotesDefect[] {
  return [];
}
