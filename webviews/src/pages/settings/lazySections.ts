// Settings loads its navigation, the search and the group lists first; each section's cards are a
// chunk of their own, a dynamic import. Chrome's Settings does the same: the basic page renders
// first and chrome/browser/resources/settings/lazy_load.ts holds the other sections, which
// ensure_lazy_loaded.ts imports after the first render. Here the section the route opens on loads
// before the first paint (mount.tsx holds the paint report for it) and each section route's
// loader loads its section, on hover or keyboard focus too (router.ts), so a section draws complete
// in its first frame; after the first paint the other sections load one at a time while the page
// is idle (`loadRestWhenIdle`). page-bundle-report.mjs reads the `<section>: () => import(...)`
// entries below and checks that the first load holds the navigation and one section at most.
import type { ReactNode } from "react";
import { categoryById, type CategoryCard } from "./categories";

/** A card's drawing: `focus` is the route's focused key, `workspace` the workspace the page was opened for. */
export type CardRender = (focus: string | null, workspace: string | null) => ReactNode;

/** What a card draws in the search results: the query and the card's rows that match it. */
export type SearchCardProps = { query: string; visibleRows: ReadonlySet<string> };
export type SearchCardRender = (props: SearchCardProps) => ReactNode;

/** What a section's module exports: its cards, and the cards the search results draw. */
export type SectionModule = {
  cards: Partial<Record<CategoryCard, CardRender>>;
  searchCards?: Partial<Record<CategoryCard, SearchCardRender>>;
};

/** Each section's chunk. A category of schema rows only (Editor, Keyboard, ...) has no code of its own. */
export const lazySections = {
  general: () => import("./sections/General"),
  updates: () => import("./sections/Updates"),
  theme: () => import("./sections/Theme"),
  appearance: () => import("./sections/Appearance"),
  terminal: () => import("./sections/Terminal"),
  agents: () => import("./sections/Agents"),
  chief: () => import("./sections/Chief"),
  browser: () => import("./sections/Browser"),
  import: () => import("./sections/Import"),
  accounts: () => import("./sections/Accounts"),
  mobile: () => import("./sections/Mobile"),
  server: () => import("./sections/Server"),
  devices: () => import("./sections/Devices"),
  advanced: () => import("./sections/Advanced"),
  experimental: () => import("./sections/Experimental"),
} satisfies Record<string, () => Promise<SectionModule>>;

export type SectionChunk = keyof typeof lazySections;
export type SectionChunks = Record<SectionChunk, () => Promise<SectionModule>>;

/** The chunk that draws each card: the section the schema's layout puts it in. */
export const CARD_CHUNKS: Record<CategoryCard, SectionChunk> = {
  spaces: "general",
  webUpdates: "updates",
  channels: "updates",
  themeStudio: "theme",
  backdrops: "appearance",
  density: "appearance",
  terminalInfo: "terminal",
  ghosttyDiagnostics: "terminal",
  harnesses: "agents",
  agentHarnesses: "agents",
  computerUse: "agents",
  agentIntegrations: "agents",
  chiefs: "chief",
  chiefPet: "chief",
  voiceInput: "chief",
  notices: "chief",
  browserProfiles: "browser",
  importSuggestions: "import",
  accounts: "accounts",
  machines: "accounts",
  cloudEnvironments: "accounts",
  mobile: "mobile",
  server: "server",
  devices: "devices",
  advancedInfo: "advanced",
  advancedActions: "advanced",
  featureFlags: "experimental",
};

/** The chunks `section`'s cards are in: one for a section with cards, none for one of rows only. */
export function sectionChunksOf(section: string): SectionChunk[] {
  const category = categoryById(section);
  return [...new Set([...category.lead, ...category.trail].map((card) => CARD_CHUNKS[card]))];
}

/** Runs `work` once the page is idle: Chrome's afterNextRender (a frame, then a task) where the
 * engine has no requestIdleCallback (WebKit). */
function whenIdle(work: () => void): () => void {
  if (typeof requestIdleCallback === "function") {
    const handle = requestIdleCallback(work);
    return () => cancelIdleCallback(handle);
  }
  let timer: ReturnType<typeof setTimeout> | undefined;
  const frame = requestAnimationFrame(() => (timer = setTimeout(work, 0)));
  return () => {
    cancelAnimationFrame(frame);
    clearTimeout(timer);
  };
}

/** The page's section code: the chunks loaded, and the loads in flight. */
export type SectionLoader = {
  /** Loads the chunks `section`'s cards are in. Never rejects: a chunk that fails to load leaves
   * its cards out, and the next load of that section tries it again. */
  load(section: string): Promise<void>;
  /** Loads the chunk `card` is in. */
  loadCard(card: CategoryCard): Promise<void>;
  /** The card's drawing, or undefined while its chunk is not loaded. */
  card(card: CategoryCard): CardRender | undefined;
  /** The card's search results drawing, or undefined while its chunk is not loaded. */
  searchCard(card: CategoryCard): SearchCardRender | undefined;
  /** Calls `listener` after each chunk loads. */
  subscribe(listener: () => void): () => void;
  /** After the first paint: loads every chunk not loaded yet, one per idle turn. */
  loadRestWhenIdle(): void;
  /** Stops the idle loads. */
  dispose(): void;
};

export function createSectionLoader(
  options: { chunks?: SectionChunks; idle?: (work: () => void) => () => void } = {},
): SectionLoader {
  const chunks = options.chunks ?? lazySections;
  const idle = options.idle ?? whenIdle;
  const modules = new Map<SectionChunk, SectionModule>();
  const loading = new Map<SectionChunk, Promise<void>>();
  const listeners = new Set<() => void>();
  let cancelIdle: (() => void) | undefined;
  let disposed = false;

  const loadChunk = (chunk: SectionChunk): Promise<void> => {
    const known = loading.get(chunk);
    if (known) return known;
    const load = chunks[chunk]().then(
      (module) => {
        modules.set(chunk, module);
        for (const listener of listeners) listener();
      },
      (error: unknown) => {
        loading.delete(chunk);
        console.warn(`settings: the ${chunk} section did not load`, error);
      },
    );
    loading.set(chunk, load);
    return load;
  };
  const moduleOf = (card: CategoryCard) => modules.get(CARD_CHUNKS[card]);

  return {
    load: async (section) => {
      await Promise.all(sectionChunksOf(section).map(loadChunk));
    },
    loadCard: (card) => loadChunk(CARD_CHUNKS[card]),
    card: (card) => moduleOf(card)?.cards[card],
    searchCard: (card) => moduleOf(card)?.searchCards?.[card],
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    loadRestWhenIdle() {
      // Each chunk is tried once here; one that fails loads again when its section is shown.
      const rest = (Object.keys(chunks) as SectionChunk[]).filter((id) => !loading.has(id) && !modules.has(id));
      const next = () => {
        cancelIdle = undefined;
        const chunk = rest.shift();
        if (disposed || !chunk) return;
        void loadChunk(chunk).then(() => {
          if (!disposed && rest.length > 0) cancelIdle = idle(next);
        });
      };
      cancelIdle?.();
      cancelIdle = idle(next);
    },
    dispose() {
      disposed = true;
      cancelIdle?.();
      listeners.clear();
    },
  };
}
