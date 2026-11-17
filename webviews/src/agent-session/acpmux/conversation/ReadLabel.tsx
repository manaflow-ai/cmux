// A call that read one file draws as one kind of row, whatever made it (readPath.ts): the book icon
// and "Read <file name>", the full path on hover, as the Codex app draws its reads (Lucas, 2026-11-14
// standup: "just have the file here ... if you hover over the file name, it'll show the rest"). A name
// alone keeps the row on one line, so opening its run shifts nothing. A read does not open.
import type { Translate } from "../i18n";
import { leadingVerb } from "./toolVerbModel";
import { ToolLabel } from "./ToolVerb";

/// "Read <file name>" in the reader's language, the name carrying its full path as its tooltip
/// (ui/titleTooltips.ts draws the `title` as the pane's glass tooltip).
export function ReadLabel({ path, full, t }: { path: string; full: string; t: Translate }) {
  const name = path.replace(/\/+$/, "").split("/").pop() || path;
  const [before = "", after = ""] = t("command.read", { file: "\u0000" }).split("\u0000");
  const file = (
    <span className="cv-tool__file" title={full} data-tooltip-force="">
      {name}
    </span>
  );
  return (
    <ToolLabel verb={after ? undefined : leadingVerb(before)} subject={file}>
      {before}
      {file}
      {after}
    </ToolLabel>
  );
}
