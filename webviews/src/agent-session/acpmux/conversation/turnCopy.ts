// What a turn's one footer copies: the whole turn, as Claude Code desktop's Copy does (Leo,
// 2026-10-31: "claude code doesn't have individual copy pastable things for the entire thing, only
// the bottom ... btw yes claude code desktop does copy all of it incl. tool call top level things..
// tho idk if we also want to to do that"). Every piece of the agent's text in order, and each run of
// tool calls between them as its one top-level line ("Ran 2 commands", "Read file.ts"), never its
// output (a turn of calls alone adds its last call's output, ``turnCopyText``). Thoughts, steers and other agents' messages are not the agent's words, so they stay out.
import type { Translate } from "../i18n";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { toolLabel } from "../toolPaths";
import { isDraftCall } from "./toolGroups";
import { toolRunSummary } from "./toolRunSummary";

/// One piece of a finished turn, in order: a reply's text, or a run of tool calls between replies.
export type TurnCopyPart = { text: string } | { tools: AcpmuxActivity[] };

/// The turn's pieces from its rows before the summary, or undefined when it has nothing to copy: the
/// agent said nothing and ran no call. A turn of tool calls alone copies its calls' lines and the last
/// call's output (`turnCopyText`), so its footer keeps Copy as every finished turn's does (G04: a turn
/// that only ran tools, or failed after them, ended on a bare "Worked for" with no Copy).
export function turnCopyParts(rows: readonly AcpmuxRow[]): TurnCopyPart[] | undefined {
  const parts: TurnCopyPart[] = [];
  let run: AcpmuxActivity[] | undefined;
  let said = false;
  let ran = false;
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
      ran = true;
    }
  }
  return said || ran ? parts : undefined;
}

/// Whether the agent said anything in `parts` (a reply's text), not only ran calls.
export const turnCopySaid = (parts: readonly TurnCopyPart[] | undefined): boolean =>
  parts?.some((part) => "text" in part) ?? false;

/// The calls of a turn that ran calls and said nothing, as its pieces (a run of calls between
/// replies, as `turnCopyParts` gives them), or undefined when it ran none: what the row of a turn the
/// agent ran on its own copies when it ended on its calls (turns.ts `backgroundFooters`).
export function turnCallParts(rows: readonly AcpmuxRow[]): TurnCopyPart[] | undefined {
  const tools = rows.flatMap((row) =>
    row.kind === "activity" ? (row.items ?? []).filter((item) => item.tool && !isDraftCall(item.tool)) : [],
  );
  return tools.length ? [{ tools }] : undefined;
}

/// The text the footer's Copy puts on the clipboard: the pieces as blocks, a run as its row's title
/// (a lone call's own label, else the run's summary line, as the transcript draws them). A turn of
/// calls alone adds the last call's output (trimmed) after its lines: the result the turn ended on.
export function turnCopyText(t: Translate, parts: readonly TurnCopyPart[]): string {
  const lines = parts
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
    .filter(Boolean);
  if (!turnCopySaid(parts)) {
    const last = parts.at(-1);
    const output = last && "tools" in last ? last.tools.at(-1)?.tool?.output?.trim() : undefined;
    if (output) lines.push(output);
  }
  return lines.join("\n\n");
}
