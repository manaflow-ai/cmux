// A shell command in a few words, for a one-line note that has no room for all of it (a background
// task's end, BackgroundTaskNote.tsx): the step that does the work, without the setup before it.
// `export PATH="…"; B=~/x; cd repo && cmux browser open …` reads "cmux browser open …" (Leo
// 2026-10-20: "a short human label, not the raw command").
import { isAssignmentOnly, mainStep, withoutAssignments, withoutHeredocMarkers } from "./shellSteps";
import { sliceWhole } from "../../../ui/wholeChars";

/// A program named by its path reads as its name: `/opt/x/bin/cmux` is `cmux`.
function programName(step: string): string {
  const match = /^(?:"([^"]+)"|'([^']+)'|(\S+))(.*)$/s.exec(step);
  if (!match) return step;
  const program = match[1] ?? match[2] ?? match[3] ?? "";
  const name = program.includes("/") ? (program.split("/").filter(Boolean).pop() ?? program) : program;
  return `${name}${match[4] ?? ""}`;
}

/// `command` in at most `max` characters: its first step that is not setup, its program by name,
/// an ellipsis where steps or words were left out. A transcript row passes no `max` (ROW_WIDTH): it
/// draws the whole step and CSS cuts it at the row's right edge (Leo, 2026-10-22: "shouldnt these
/// also ellipsis later"); a one-line note with no room keeps the cap.
export function shortCommand(command: string, max = 60): string {
  // The step that does the work (shellSteps.ts): setup and plumbing before it go, each word whole.
  const { step, more } = mainStep(command);
  if (!step) return "";
  // A step that is only assignments reads whole: its first word is no program to shorten.
  const bare = withoutHeredocMarkers(withoutAssignments(step));
  let text = (isAssignmentOnly(bare) ? bare : programName(bare)).replace(/\s+/g, " ");
  if (text.length > max) text = `${sliceWhole(text, max - 1).trimEnd()}…`;
  else if (more) text = `${text} …`;
  return text;
}

/// The command line shown as activity in a running tray row. Unlike `shortCommand`, this keeps
/// the command's actual shell text (including later steps such as `; echo t`) and only trims it to
/// the available single-line width.
export function trimRawCommand(command: string, max = 60): string {
  // Keep spaces inside quoted shell arguments intact; only flatten line breaks so the activity fits
  // one visual line without changing the command a person recognizes.
  const text = command.trim().replace(/[\r\n]+/g, " ");
  if (text.length <= max) return text;
  return `${sliceWhole(text, Math.max(1, max - 1)).trimEnd()}…`;
}

/// No character cap: the row's CSS ellipsis cuts the line where the row ends.
export const ROW_WIDTH = Number.POSITIVE_INFINITY;
