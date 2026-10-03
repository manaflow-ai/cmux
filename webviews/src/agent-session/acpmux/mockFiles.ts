// The mock daemon's file search: what `file.search` answers for the seeded projects.
// Each project has a small tree; the query matches as a fuzzy subsequence of the path, and a
// match in the file's name ranks above one spread through its folders, as a quick-open does.
import { OUTSIDE_REPOSITORY, type FileMatch, type FileSearchResult } from "./fileSearchModel";

const trees: Record<string, string[]> = {
  "~/code/cmux": [
    "README.md",
    "package.json",
    "Package.swift",
    "Sources/Fleet/upload.ts",
    "Sources/Fleet/upload.test.ts",
    "Sources/Fleet/retry.ts",
    "Sources/Fleet/manifest.ts",
    "Sources/Fleet/README.md",
    "Sources/Panels/TerminalPanelView.swift",
    "Sources/Panels/BrowserPanelView.swift",
    "Sources/GhosttyTerminalView.swift",
    "Sources/ContentView.swift",
    "Sources/SessionIndexView.swift",
    "Resources/Localizable.xcstrings",
    "webviews/src/agent-session/acpmux/Composer.tsx",
    "webviews/src/agent-session/acpmux/styles.css",
    "docs/agent-pane.md",
    "scripts/reload.sh",
  ],
  "~/code/acpmux": ["README.md", "Cargo.toml", "src/main.rs", "src/session.rs", "src/replay.rs", "src/trust.rs"],
  "~/code/atlas-web": ["README.md", "package.json", "src/app/App.tsx", "src/app/home.tsx", "src/theme.css"],
  "~/code/billing-service": ["README.md", "go.mod", "cmd/server/main.go", "stripe/webhooks.go", "stripe/seats.go"],
  "~/code/dotfiles": [".zshrc", ".gitconfig", "nvim/init.lua", "README.md"],
};

/// The positions of `query`'s characters in `path`, in order and case-insensitively, preferring
/// a run inside the file's name; undefined when the path doesn't contain them all.
function fuzzy(path: string, query: string): { matches: number[]; score: number } | undefined {
  const lower = path.toLowerCase();
  const wanted = query.toLowerCase().replace(/\s+/g, "");
  const name = lower.lastIndexOf("/") + 1;
  const scan = (from: number) => {
    const matches: number[] = [];
    let at = from;
    for (const char of wanted) {
      const found = lower.indexOf(char, at);
      if (found < 0) return undefined;
      matches.push(found);
      at = found + 1;
    }
    return matches;
  };
  const inName = scan(name);
  const matches = inName ?? scan(0);
  if (!matches) return undefined;
  let gaps = 0;
  for (let index = 1; index < matches.length; index++) gaps += matches[index]! - matches[index - 1]! - 1;
  return { matches, score: (inName ? 0 : 1000) + gaps * 10 + path.length };
}

/// The wire reply: the projects are each a repository's top level, so `search_root` is `root`.
export function mockFileSearch(
  cwd: string | undefined,
  query: unknown,
  limit: unknown,
): FileSearchResult & { search_root: string } {
  const root = cwd ?? "~";
  // As the service: a folder outside a repository fails, naming the path.
  if (!trees[root])
    throw Object.assign(new Error(`${root} is not in a git repository`), {
      code: "operation.failed",
      details: { operation: "git.files.search", reason: `${root} is not in a git repository`, extra: { code: OUTSIDE_REPOSITORY } },
    });
  const text = typeof query === "string" ? query.trim() : "";
  if (!text) return { root, search_root: root, results: [] };
  const max = Math.min(typeof limit === "number" && limit > 0 ? limit : 50, 200);
  const ranked = (trees[root] ?? [])
    .flatMap((path) => {
      const hit = fuzzy(path, text);
      return hit ? [{ path, matches: hit.matches, score: hit.score }] : [];
    })
    .sort((left, right) => left.score - right.score || left.path.localeCompare(right.path));
  const results: FileMatch[] = ranked.slice(0, max).map(({ path, matches }) => ({ path, matches }));
  return { root, search_root: root, results, truncated: ranked.length > max };
}
