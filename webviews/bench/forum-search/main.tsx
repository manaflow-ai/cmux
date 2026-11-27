// l10n-allow-file: bench fixture thread text, not shipped UI.
// The Forum page (pages/forum/ForumPage.tsx, the shipped "columns" layout) over THREADS threads, for
// forum-search.bench.ts, which types into its search field and reads how long each keystroke holds the
// frame. A Profiler around the page records each commit's own time (the build aliases react-dom to its
// profiling build).
//   #threads=2000
/// <reference types="vite/client" />
import { Profiler } from "react";
import { createRoot } from "react-dom/client";
import { ForumPage } from "../../src/pages/forum/ForumPage";
import type { ForumSnapshot, ForumThread } from "../../src/pages/forum/types";
import type { Strings } from "../../src/pages/shared/i18n";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/forum/styles.css";

const params = new URLSearchParams(location.hash.slice(1));
const THREADS = Number(params.get("threads") ?? 2000);
const NOW = Date.UTC(2026, 10, 5, 3);

declare global {
  interface Window {
    benchReady: boolean;
    /// [commitTime, actualDuration] of each commit under the Profiler.
    benchCommits: [number, number][];
    /// Event Timing entries (trusted key events: start to the next paint), as INP reads them.
    benchEvents: { name: string; interactionId: number; duration: number }[];
    /// How many threads the page should list for `query` (ForumPage's own match: title or body).
    benchExpected: (query: string) => number;
  }
}
window.benchCommits = [];
window.benchEvents = [];
new PerformanceObserver((list) => {
  for (const entry of list.getEntries() as PerformanceEventTiming[])
    window.benchEvents.push({ name: entry.name, interactionId: entry.interactionId, duration: entry.duration });
}).observe({ type: "event", durationThreshold: 16, buffered: true } as PerformanceObserverInit);

const WORDS = ["linker", "sidebar", "theme", "settings", "drag", "toolchain", "review", "handbook", "cache", "socket"];
const KINDS = ["question", "finding", "article", "page"] as const;
const STATES = ["open", "answered", "closed"] as const;
const threads: ForumThread[] = Array.from({ length: THREADS }, (_, index) => ({
  number: THREADS - index,
  title: `The ${WORDS[index % WORDS.length]} ${WORDS[(index * 7) % WORDS.length]} issue number ${index}`,
  body: `Measured on build-${index % 8}: the ${WORDS[(index * 3) % WORDS.length]} path takes ${index % 90} ms.`,
  state: STATES[index % 3]!,
  kind: KINDS[index % 4]!,
  labels: [],
  author: {
    kind: index % 2 ? "agent" : "person",
    id: `u${index % 20}`,
    name: `author${index % 20}`,
    on_behalf_of: index % 2 ? "Ada" : null,
  },
  space: ["general", "fleet", "users"][index % 3]!,
  comments: index % 11,
  created_at: NOW - index * 120_000,
  updated_at: NOW - index * 60_000,
  unread: index % 5 === 0,
}));
const snapshot: ForumSnapshot = {
  status: "ready",
  team: "Bench Team",
  feed: "live",
  spaces: [
    { name: "general", visibility: "private", threads: THREADS / 3 },
    { name: "fleet", visibility: "private", threads: THREADS / 3 },
    { name: "users", visibility: "public", threads: THREADS / 3 },
  ],
  threads,
  comments: {},
} as ForumSnapshot;

window.benchExpected = (query) => {
  const q = query.trim().toLowerCase();
  return threads.filter(
    (thread) => !q || thread.title.toLowerCase().includes(q) || thread.body.toLowerCase().includes(q),
  ).length;
};

const strings: Strings = { language: "en", t: (key) => key, format: (key, ...args) => [key, ...args].join(" ") };
createRoot(document.getElementById("root")!).render(
  <Profiler
    id="forum"
    onRender={(_id, _phase, actual, _base, _start, commit) => window.benchCommits.push([commit, actual])}
  >
    <ForumPage snapshot={snapshot} strings={strings} layout="columns" now={NOW} />
  </Profiler>,
);
requestAnimationFrame(() => requestAnimationFrame(() => (window.benchReady = true)));
