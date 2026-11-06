// A file chip's icon by the file's kind (fileKindIcon.experiment.ts): a page for a document,
// braces for code and data, a terminal mark for a log, so a reply's "Supporting artifacts:" line
// reads as typed links, as ChatGPT's report does.
import { experimentArm } from "../../../experiments/experiment";
import { CodeBrackets, FileDoc, TerminalSquare } from "../conversation/icons";
import { fileKindIcon } from "./fileKindIcon.experiment";

export type FileKind = "doc" | "code" | "log";

const CODE =
  /\.(?:json|jsonl|ndjson|ya?ml|toml|ini|plist|csv|tsv|xml|ts|tsx|js|jsx|mjs|cjs|rs|swift|py|go|rb|java|kt|kts|c|h|cc|cpp|hpp|m|mm|cs|php|lua|zig|ex|exs|sh|bash|zsh|fish|sql|css|scss|html|vue|svelte|proto|graphql|gql)$/i;
const LOG = /\.(?:log|out|err|trace)$/i;

/** What a path's file is, from its extension (a `:line` suffix and a query are ignored). */
export function fileKind(path: string): FileKind {
  const name = path.replace(/[?#].*$/, "").replace(/:\d+(?::\d+)?$/, "");
  if (LOG.test(name)) return "log";
  if (CODE.test(name)) return "code";
  return "doc";
}

export function FileKindIcon({ path, size = 16, className }: { path: string; size?: number; className?: string }) {
  const arm = experimentArm(fileKindIcon);
  const kind = arm === "page" ? "doc" : arm === "code-only" && fileKind(path) === "log" ? "code" : fileKind(path);
  const props = { size, strokeWidth: 1.1, className: `${className ?? ""} cv-file-kind--${kind}`.trim() };
  if (kind === "code") return <CodeBrackets {...props} />;
  if (kind === "log") return <TerminalSquare {...props} />;
  return <FileDoc {...props} />;
}
