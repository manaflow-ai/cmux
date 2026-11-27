// l10n-allow-file: bench fixture review text, not shipped UI.
// The GitHub page (pages/github/GitHubPage.tsx) over a stand-in store, for github-slices.bench.ts: a pull
// request with FILES files and ENTRIES conversation entries (each with a review comment on an open thread),
// so the bench can change one slice of the snapshot (a file's patch, the person's write) and read what
// React spent on it. A Profiler around the page records each commit's own time (the build aliases react-dom
// to its profiling build).
//   #files=120&entries=200
/// <reference types="vite/client" />
import { Profiler } from "react";
import { createRoot } from "react-dom/client";
import { GitHubPage } from "../../src/pages/github/GitHubPage";
import { MOCK_URL, mockDetails, mockPullRequest } from "../../src/pages/github/mockProvider";
import type { GitHubSnapshot, GitHubStore } from "../../src/pages/github/store";
import type { ConversationEntry } from "../../src/pages/github/types";
import type { Strings } from "../../src/pages/shared/i18n";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/github/styles.css";

const params = new URLSearchParams(location.hash.slice(1));
const FILES = Number(params.get("files") ?? 120);
const ENTRIES = Number(params.get("entries") ?? 200);

declare global {
  interface Window {
    benchReady: boolean;
    /// [commitTime, actualDuration] of each commit under the Profiler.
    benchCommits: [number, number][];
    /// Opens or closes file `index`'s patch (a new `patches` object, as the store's toggleFile does).
    benchPatch: (index: number) => void;
    /// Sets the person's write phase (a new `write`, as submitReview does).
    benchWrite: (sending: boolean) => void;
  }
}
window.benchCommits = [];

const files = Array.from({ length: FILES }, (_, index) => ({
  path: `Sources/Module${index % 12}/File${index}.swift`,
  additions: (index * 7) % 90,
  deletions: (index * 3) % 40,
}));
const conversation: ConversationEntry[] = Array.from(
  { length: ENTRIES },
  (_, index) =>
    ({
      kind: index % 3 === 0 ? "review" : "comment",
      author: `reviewer${index % 9}`,
      body: `Point ${index}: the **sidebar** keeps its order after a drag; see \`File${index}.swift\`.`,
      at: new Date(Date.UTC(2026, 10, 5) - index * 60_000).toISOString(),
      url: `${MOCK_URL}#discussion-${index}`,
      state: index % 3 === 0 ? "commented" : null,
      comments:
        index % 3 === 0
          ? [
              {
                path: files[index % FILES]!.path,
                line: index,
                body: `Nit ${index}.`,
                url: `${MOCK_URL}#r${index}`,
                thread: `T${index}`,
                resolved: false,
              },
            ]
          : [],
    }) as ConversationEntry,
);

let snapshot: GitHubSnapshot = {
  target: { url: MOCK_URL, repo: "example/app", number: 482 },
  pullRequest: { ...mockPullRequest, state: "open", files, changedFiles: FILES },
  details: { ...mockDetails, conversation, conversationTotal: ENTRIES, conversationRead: ENTRIES },
  reading: false,
  answered: true,
  patches: {},
  merge: { phase: "idle" },
  rerun: { phase: "idle" },
  write: { phase: "idle" },
};
const listeners = new Set<() => void>();
const set = (next: GitHubSnapshot) => {
  snapshot = next;
  for (const listener of listeners) listener();
};
const base = {
  subscribe: (listener: () => void) => {
    listeners.add(listener);
    return () => void listeners.delete(listener);
  },
  getSnapshot: () => snapshot,
};
// Every action the page might call is a no-op here; the bench drives the snapshot itself.
const store = new Proxy(base, {
  get: (target, key) => (key in target ? target[key as keyof typeof target] : () => undefined),
}) as unknown as GitHubStore;

window.benchPatch = (index) => {
  const path = files[index % FILES]!.path;
  const { [path]: open, ...rest } = snapshot.patches;
  set({ ...snapshot, patches: open ? rest : { ...snapshot.patches, [path]: { state: "loading" } } });
};
window.benchWrite = (sending) =>
  set({ ...snapshot, write: sending ? { phase: "sending", what: "review" } : { phase: "idle" } } as GitHubSnapshot);

const strings: Strings = { language: "en", t: (key) => key, format: (key, ...args) => [key, ...args].join(" ") };
createRoot(document.getElementById("root")!).render(
  <Profiler
    id="github"
    onRender={(_id, _phase, actual, _base, _start, commit) => window.benchCommits.push([commit, actual])}
  >
    <GitHubPage store={store} strings={strings} now={() => Date.UTC(2026, 10, 5, 3)} />
  </Profiler>,
);
requestAnimationFrame(() => requestAnimationFrame(() => (window.benchReady = true)));
