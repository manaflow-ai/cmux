// A run of tool calls between two pieces of text, summarized once it settles:
// "Edited a file, read files, ran commands", opened to list the calls.
import type { Translate } from "../i18n";
import type { AcpmuxActivity, AcpmuxRow } from "../model";

/// What a call did, in the order a run's summary names them.
export type ToolRunCategory = "used" | "edited" | "read" | "searched" | "web" | "ran";

const ORDER: ToolRunCategory[] = ["used", "edited", "read", "searched", "web", "ran"];

/// ACP tool kinds (`ToolKind`) to the summary's categories.
export function toolRunCategory(kind?: string): ToolRunCategory {
  switch (kind) {
    case "edit":
    case "delete":
    case "move":
    case "fileChange":
      return "edited";
    case "read":
      return "read";
    case "search":
      return "searched";
    case "fetch":
      return "web";
    case "execute":
      return "ran";
    default:
      return "used";
  }
}

/// A run folds under one summary line once it holds two or more calls.
export function isFoldedRun(items: readonly AcpmuxActivity[]): boolean {
  return items.filter((item) => item.tool).length >= 2;
}

/// The Debug toggle `agentPane.debug.workedForFoldsRuns` (off by default), which the app sets on
/// `<html>` as `data-worked-for-runs="fold"`: an open "Worked for" folds each run again, as Codex does.
export const workedForRuns = {
  fold: () => typeof document !== "undefined" && document.documentElement.dataset.workedForRuns === "fold",
};

/// Whether a row's run draws as its summary line: a live turn's run that a later row followed, under
/// the Codex-style runs (turns.ts `codexRuns` marks it `foldRun`), or with the Debug toggle on, a run
/// in an ended turn's open "Worked for" (`settled`). Otherwise an open "Worked for" lists every
/// step, so the run's height and the reader's place don't change under it.
export function foldsRun(row: AcpmuxRow, items: readonly AcpmuxActivity[] = row.items ?? []): boolean {
  return (row.foldRun === true || (row.settled === true && workedForRuns.fold())) && isFoldedRun(items);
}

/// The categories a run's calls fall in, in summary order. Searches count as reads when the
/// run also reads files, as in "Read files, ran commands".
export function toolRunCategories(items: readonly AcpmuxActivity[]): ToolRunCategory[] {
  const present = new Set(items.filter((item) => item.tool).map((item) => toolRunCategory(item.tool!.kind)));
  if (present.has("read")) present.delete("searched");
  return ORDER.filter((category) => present.has(category));
}

/// "Edited a file, read files, ran commands", in the language `t` speaks.
export function toolRunSummary(t: Translate, items: readonly AcpmuxActivity[]): string {
  const tools = items.filter((item) => item.tool);
  const count = (category: ToolRunCategory) =>
    tools.filter((item) => {
      const own = toolRunCategory(item.tool!.kind);
      return own === category || (category === "read" && own === "searched");
    }).length;
  const phrase = (category: ToolRunCategory) => {
    const one = count(category) === 1;
    switch (category) {
      case "used":
        return one ? t("toolRun.used.one") : t("toolRun.used.other");
      case "edited":
        return one ? t("toolRun.edited.one") : t("toolRun.edited.other");
      case "read":
        return one ? t("toolRun.read.one") : t("toolRun.read.other");
      case "searched":
        return t("toolRun.searched");
      case "web":
        return t("toolRun.web");
      case "ran":
        return one ? t("toolRun.ran.one") : t("toolRun.ran.other");
    }
  };
  // A catalog separator, not Intl.ListFormat: its unit lists join zh-Hans with nothing and add
  // conjunctions in some languages, while the run reads as a plain comma list.
  const text = toolRunCategories(items).map(phrase).join(t("toolRun.separator"));
  return text.charAt(0).toUpperCase() + text.slice(1);
}
