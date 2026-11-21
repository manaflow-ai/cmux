// A file chip's icon by the file's kind (fileKindIcon.experiment.ts): a page for a document,
// braces for code and data, a terminal mark for a log, so a reply's "Supporting artifacts:" line
// reads as typed links, as ChatGPT's report does.
import { experimentArm } from "../../../experiments/experiment";
import { CodeBrackets, FileDoc, TerminalSquare } from "../conversation/icons";
import { fileKindIcon } from "./fileKindIcon.experiment";
import { fileKind } from "./fileKindIconModel";
export function FileKindIcon({ path, size = 16, className }: { path: string; size?: number; className?: string }) {
  const arm = experimentArm(fileKindIcon);
  const kind = arm === "page" ? "doc" : arm === "code-only" && fileKind(path) === "log" ? "code" : fileKind(path);
  const props = { size, strokeWidth: 1.1, className: `${className ?? ""} cv-file-kind--${kind}`.trim() };
  if (kind === "code") return <CodeBrackets {...props} />;
  if (kind === "log") return <TerminalSquare {...props} />;
  return <FileDoc {...props} />;
}
