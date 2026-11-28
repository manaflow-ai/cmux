// l10n-allow-file: bench fixture titles, not shipped UI.
// What's New's day list and the Updated card's list over N items, for
// bench/changelog-visible-only.bench.ts: `#n=10000&kind=sheet|journal|card`. The pages read N builds
// (one a day) from a stand-in host that holds the second build's notes until the bench lets them
// load (`benchChangeOne`); the card draws N changes and the bench changes one's detail.
// `benchRowRenders` counts the rows that rendered since its last mark, read from each mounted row's
// fiber (test/support/mountedRowRenders.ts), so the page carries no counter.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/ui/ui.css";
import "../../src/pages/changelog/styles.css";
import "../../src/ui/glass/composerMaterial.css";
import "../../src/pages/changelog/updateSurfaces.css";
import "../../src/pages/changelog/surface.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import type { PageClient } from "../../src/pages/shared/pageClient";
import table from "../../src/pages/changelog/generated/strings.json";
import { ChangelogPage } from "../../src/pages/changelog/ChangelogPage";
import { ChangelogStore } from "../../src/pages/changelog/store";
import type { IndexEntry, ReleaseNotes } from "../../src/pages/changelog/types";
import type { UpdateHighlights } from "../../src/pages/changelog/updateHighlights";
import { UpdatedNotes } from "../../src/pages/changelog/UpdatedNotes";
import { UiProvider } from "../../src/ui/UiProvider";
import { mountedRowRenders } from "../support/mountedRowRenders";

/** `benchRowRenders` and `benchKeptRenders` over the rows `rows` finds. */
function countRenders(rows: () => NodeListOf<Element>) {
  window.benchRowRenders = mountedRowRenders(rows);
  let marked = new Set<Element>();
  const kept = mountedRowRenders(() => [...rows()].filter((row) => marked.has(row)));
  window.benchKeptRenders = {
    mark() {
      marked = new Set(rows());
      kept.mark();
    },
    since: () => kept.since(),
  };
}

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** The same count over the rows that were mounted at the mark only: renders of rows that stayed,
        not rows that mounted since. */
    benchKeptRenders: { mark(): void; since(): number };
    /** Pages: the held build's notes load. Card: the `index`th change's detail changes. */
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const params = new URLSearchParams(location.hash.slice(1));
const n = Number(params.get("n") ?? 1000);
const kind = params.get("kind") ?? "sheet";
const root = document.getElementById("root")!;
const strings = createStrings(table, ["en"]);
const react = createRoot(root);
const AREAS = ["Sidebar", "Terminal", "Browser tabs", "Agent chat", "Settings search"];

if (kind === "card") {
  document.documentElement.dataset.surface = "updated-notes";
  const kinds = ["new", "improved", "fixed"] as const;
  const data = (changed?: number): UpdateHighlights => {
    const items = Array.from({ length: n }, (_, i) => ({
      id: `c${i}`,
      title: `${AREAS[i % AREAS.length]} keeps its place after change ${i}`,
      summary: i === changed ? `Changed ${Date.now()}.` : `What change ${i} does, in one plain sentence.`,
      category: kinds[i % 3]!,
    }));
    return {
      version: "1.0.0-nightly.5000000000000",
      build: "5000000000000",
      fromVersion: "1.0.0-nightly.4000000000000",
      fromBuild: "4000000000000",
      source: "whatsNew",
      language: "en",
      items: items.slice(0, 3),
      rest: items.slice(3),
      moreCount: n - 3,
      changelog: { from: "1.0.0-nightly.4000000000000", to: "1.0.0-nightly.5000000000000" },
    };
  };
  const actions = { openChangelog: () => {} };
  const draw = (changed?: number) =>
    react.render(
      <UiProvider container={root}>
        <UpdatedNotes data={data(changed)} strings={strings} actions={actions} mode="beside" />
      </UiProvider>,
    );
  draw();
  countRenders(() => document.querySelectorAll(".wn-notes-row"));
  window.benchChangeOne = async (index) => draw(index);
  window.benchReady = true;
} else {
  const builds: IndexEntry[] = Array.from({ length: n }, (_, i) => {
    const build = String(5_000_000_000_000 - i);
    const date = new Date(Date.UTC(2026, 10, 18) - i * 86_400_000).toISOString().slice(0, 10);
    return { build, shortVersion: `1.0.0-nightly.${build}`, date, highlights: 3 };
  });
  const byBuild = new Map(builds.map((b) => [b.build, b]));
  const held = builds[1]!.build;
  let release = () => {};
  const waiting = new Promise<void>((resolve) => (release = resolve));
  const notes = (b: IndexEntry): ReleaseNotes => {
    const titles = [0, 1, 2].map((k) => `${AREAS[(Number(b.build) + k) % AREAS.length]} keeps its place on ${b.date}`);
    return {
      build: b.build,
      shortVersion: b.shortVersion,
      date: b.date,
      highlights: [],
      changes: titles.map((title, k) => `${title} (#${30_000 + k})`),
      items: titles.map((title, k) => ({ title, pr: 30_000 + k })),
    };
  };
  const client = {
    async call(op: string, p: { build?: string }) {
      if (op === "cmux.changelog.list") return { current: builds[0]!.build, builds };
      if (op === "cmux.changelog.get") {
        const b = byBuild.get(p.build ?? "");
        if (!b) throw new Error("not found");
        if (b.build === held) await waiting;
        return notes(b);
      }
      if (op === "cmux.changelog.installable") return { installs: false };
      return {};
    },
  } as unknown as PageClient;
  const store = new ChangelogStore(client);
  react.render(
    <UiProvider container={root}>
      <ChangelogPage store={store} strings={strings} design={kind === "journal" ? "journal" : "sheet"} />
    </UiProvider>,
  );
  countRenders(() => document.querySelectorAll(".clj-section:not(.clj-span)"));
  window.benchChangeOne = async () => {
    release();
    await store.ensure(held);
  };
  void store.start().then(() => {
    window.benchReady = true;
  });
}
