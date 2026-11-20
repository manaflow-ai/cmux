// What a turn's one footer copies: the whole turn, as Claude Code desktop's Copy does (Leo,
// 2026-10-31: "claude code doesn't have individual copy pastable things for the entire thing, only
// the bottom ... btw yes claude code desktop does copy all of it incl. tool call top level things..
// tho idk if we also want to to do that"). Every piece of the agent's text in order, and each run of
// tool calls between them as its one top-level line ("Ran 2 commands", "Read file.ts"), never its
// output. Thoughts, steers and other agents' messages are not the agent's words, so they stay out.
import type { Translate } from "../i18n";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { toolLabel } from "../toolPaths";
import { isDraftCall } from "./toolGroups";
import { toolRunSummary } from "./toolRunSummary";

/// One piece of a finished turn, in order: a reply's text, or a run of tool calls between replies.
export type TurnCopyPart = { text: string } | { tools: AcpmuxActivity[] };

/// The turn's pieces from its rows before the summary, or undefined when the agent said nothing:
/// a turn of tool calls alone has nothing to copy, so its footer draws no Copy (Claude Code's).
export function turnCopyParts(rows: readonly AcpmuxRow[]): TurnCopyPart[] | undefined {
  const parts: TurnCopyPart[] = [];
  let run: AcpmuxActivity[] | undefined;
  let said = false;
  for (const row of rows) {
    if (row.kind === "assistant") {
      const text = (row.text ?? "").trim();
      if (!text) continue;
      run = undefined;
      parts.push({ text });
      said = true;
    } else if (row.kind === "user") {
      // A steer is visible between tool runs in the opened turn. Keep the copied
      // top-level lines in the same order as the transcript instead of merging
      // work from before and after that steer into one block.
      run = undefined;
    } else if (row.kind === "activity") {
      // A draft call the transcript hides (turns.ts withoutDrafts) is not copied either.
      const tools = (row.items ?? []).filter((item) => item.tool && !isDraftCall(item.tool));
      if (!tools.length) continue;
      if (!run) parts.push({ tools: (run = []) });
      run.push(...tools);
    }
  }
  return said ? parts : undefined;
}

/// The text the footer's Copy puts on the clipboard: the pieces as blocks, a run as its row's title
/// (a lone call's own label, else the run's summary line, as the transcript draws them).
export function turnCopyText(t: Translate, parts: readonly TurnCopyPart[]): string {
  return parts
    .map((part) => {
      if ("text" in part) return part.text;
      if (part.tools.length > 1) return toolRunSummary(t, part.tools);
      const item = part.tools[0]!;
      return toolLabel(
        item.tool!,
        item.text,
        (command) => t("tools.ranCommand", { command }),
        undefined,
        t("tools.ranUnnamed"),
      );
    })
    .filter(Boolean)
    .join("\n\n");
}
