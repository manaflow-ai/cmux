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
