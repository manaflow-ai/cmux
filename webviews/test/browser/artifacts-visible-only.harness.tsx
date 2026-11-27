// l10n-allow-file: bench fixture text, not shipped UI.
// The real Artifacts page over one file of N lines (`#n=10000`), for
// bench/artifacts-visible-only.bench.ts: a stand-in host whose file has HISTORY_LIMIT revisions, the
// newest with no parent, so its change is every line added. The bench can rename one older revision
// and have the page read the file again. `benchRowRenders` and `benchCommitRenders` count the diff
// lines and the history rows that rendered since their last mark, read from each mounted row's fiber
// (test/support/mountedRowRenders.ts), so the page carries no counter.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/artifacts/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/artifacts/generated/strings.json";
import { ArtifactsPage } from "../../src/pages/artifacts/ArtifactsPage";
import { ArtifactsStore, HISTORY_LIMIT } from "../../src/pages/artifacts/store";
import { ArtifactsOps, type ArtifactCommit } from "../../src/pages/artifacts/types";
import type { PageClient } from "../../src/pages/shared/pageClient";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    benchCommitRenders: { mark(): void; since(): number };
    /** Renames one older revision and has the page read the file and its history again. */
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const PATH = "notes/big.md";
const sha = (index: number) => index.toString(16).padStart(40, "0");
const text =
  Array.from({ length: n }, (_, index) => `const line${index} = "${"x".repeat(index % 60)}"; // ${index}`).join("\n") +
  "\n";
const commits: ArtifactCommit[] = Array.from({ length: HISTORY_LIMIT }, (_, index) => ({
  sha: sha(index + 1),
  parents: [],
  message: `Revision ${index}`,
  authorName: "cmux",
  time: Date.UTC(2026, 10, 18) - index * 60_000,
  trailers: { harness: "claude", machine: "bench" },
}));

const client: PageClient = {
  call: async <R,>(op: string, params: unknown): Promise<R> => {
    const { ref } = (params ?? {}) as { ref?: string };
    if (op === ArtifactsOps.tree)
      return { ref: "main", sha: sha(1), entries: [{ name: "big.md", path: PATH, type: "blob" }] } as R;
    if (op === ArtifactsOps.history) return { commits: commits.map((commit) => ({ ...commit })) } as R;
    return { path: PATH, size: text.length, contentType: "text/markdown", commit: ref ?? sha(1), content: text } as R;
  },
  subscribe: async () => () => {},
  handle: () => () => {},
};

const store = new ArtifactsStore(client);
const root = document.getElementById("root")!;
createRoot(root).render(<ArtifactsPage store={store} strings={createStrings(table, ["en"])} />);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".artifacts-line"));
window.benchCommitRenders = mountedRowRenders(() => document.querySelectorAll(".artifacts-commit"));
let renamed = 0;
window.benchChangeOne = async () => {
  commits[3] = { ...commits[3]!, message: `Revision 3, renamed ${++renamed}` };
  await store.select(PATH, true);
};
void store.start().then(() => {
  window.benchReady = true;
});
