// l10n-allow-file: sample looks (names, taglines, repos, consent cards), not shipped UI.
// Settings > Appearance > Looks as `cmux --json setup gallery|preview|install` answers it (cmux-tui
// `cli/setup`), for the mock host, the gallery and tests. `runLooks` changes the stack the way the
// CLI does: an install goes on top, `order` takes every id top first, remove takes it out.
import type { Look, LookConsentCard, LookLayer, LookPreview, LooksGallery, LooksRun } from "./ops";

type Seed = {
  id: string;
  name: string;
  tagline: string;
  traits: string[];
  repo: string;
  tags: string[];
  colors: Palette;
};
type Palette = { dark: [string, string, string, string]; light: [string, string, string, string] };

/** The reviewed catalog's looks (cmux-customize `setup/looks.json`), with the colors their mock
 * previews draw: window, sidebar, bubble, accent. */
const SEEDS: Seed[] = [
  {
    id: "manaflow-ai/studio-look",
    name: "Studio",
    tagline: "Dark and compact.",
    traits: ["Black", "Compact"],
    repo: "github.com/manaflow-ai/cmux-studio-look",
    tags: ["chat", "dark"],
    colors: { dark: ["#16161a", "#1f1f25", "#2a2a33", "#f0a35e"], light: ["#f6f4f0", "#ece8e1", "#ffffff", "#c8743a"] },
  },
  {
    id: "manaflow-ai/paper-look",
    name: "Paper",
    tagline: "Warm, roomy, serif replies.",
    traits: ["Light", "Roomy"],
    repo: "github.com/manaflow-ai/cmux-paper-look",
    tags: ["chat", "light"],
    colors: { dark: ["#1c1b19", "#252421", "#2f2d29", "#d9cdb4"], light: ["#fbf8f1", "#f1ece0", "#ffffff", "#3a352c"] },
  },
  {
    id: "manaflow-ai/newtab-cards-look",
    name: "New Tab Cards",
    tagline: "New Tab with recent chats as cards.",
    traits: ["New Tab", "Cards"],
    repo: "github.com/manaflow-ai/cmux-newtab-cards-look",
    tags: ["new tab"],
    colors: { dark: ["#111418", "#1a1f26", "#232a33", "#d98ad9"], light: ["#f3f6fa", "#e6ecf3", "#ffffff", "#a0479f"] },
  },
  {
    id: "manaflow-ai/newtab-threads-look",
    name: "New Tab Threads",
    tagline: "New Tab with every chat listed.",
    traits: ["New Tab", "List"],
    repo: "github.com/manaflow-ai/cmux-newtab-threads-look",
    tags: ["new tab"],
    colors: { dark: ["#131313", "#1b1b1b", "#262626", "#8bd17c"], light: ["#f7f7f7", "#ededed", "#ffffff", "#3f8f33"] },
  },
];

/** The gallery's four looks as `setup/looks.json` lists them, under names of our own (Leo,
 * 2026-11-27: "we need to have at least SOMETHING you root for", "and obv dont call it t3 code and
 * whatnot"), with their themes' colors. */
const SHIPPED: Seed[] = [
  {
    id: "manaflow-ai/codex-profile",
    name: "Pebble",
    tagline: "Clean, quiet, sidebar of threads.",
    traits: ["Light", "Round corners"],
    repo: "github.com/manaflow-ai/cmux/examples/looks/codex/profile@feat-cmux-next",
    tags: ["chat", "sidebar", "new-tab"],
    colors: { dark: ["#ffffff", "#f9f9f9", "#ececec", "#777777"], light: ["#ffffff", "#f9f9f9", "#ececec", "#777777"] },
  },
  {
    id: "manaflow-ai/claude-code-profile",
    name: "Kiln",
    tagline: "Warm tones, roomy chat.",
    traits: ["Dark", "Warm"],
    repo: "github.com/manaflow-ai/cmux/examples/looks/claude-code/profile@feat-cmux-next",
    tags: ["chat", "sidebar", "new-tab"],
    colors: { dark: ["#191919", "#282524", "#302d2b", "#d97757"], light: ["#191919", "#282524", "#302d2b", "#d97757"] },
  },
  SEEDS[0]!,
  SEEDS[1]!,
];

/** The gallery as the shipped catalog answers it, nothing installed. */
export function mockShippedLooks(): LooksGallery {
  return {
    looks: SHIPPED.map(({ colors: _colors, ...seed }): Look => ({ ...seed, installed: null })),
    stack: [],
  };
}

const COMMITS: Record<string, string> = {
  "manaflow-ai/studio-look": "4c1d7e09a2b35f6e8d90c1a2b3c4d5e6f7a8b9c0",
  "manaflow-ai/paper-look": "e983f57b2c4d6e8f0a1b3c5d7e9f1a2b4c6d8e0f",
  "manaflow-ai/newtab-cards-look": "7a2e4c6b8d0f1a3c5e7b9d1f3a5c7e9b1d3f5a7c",
  "manaflow-ai/newtab-threads-look": "b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3",
};

const seedOf = (id: string) => [...SEEDS, ...SHIPPED].find((seed) => seed.id === id);

/** A mock golden sample: a small chat window in the look's colors (an SVG, so no binary fixture). */
export function mockPreviewUrl(id: string, scheme: "light" | "dark"): string {
  const [windowColor, sidebar, bubble, accent] = (seedOf(id)?.colors ?? SEEDS[0]!.colors)[scheme];
  const svg = [
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 200">`,
    `<rect width="320" height="200" fill="${windowColor}"/>`,
    `<rect width="84" height="200" fill="${sidebar}"/>`,
    ...[24, 44, 64, 84].map(
      (y, i) =>
        `<rect x="12" y="${y}" width="${i === 0 ? 60 : 48}" height="8" rx="4" fill="${i === 0 ? accent : bubble}"/>`,
    ),
    `<rect x="104" y="24" width="150" height="34" rx="10" fill="${bubble}"/>`,
    `<rect x="150" y="70" width="150" height="26" rx="10" fill="${accent}" opacity="0.85"/>`,
    `<rect x="104" y="108" width="190" height="44" rx="10" fill="${bubble}"/>`,
    `<rect x="104" y="166" width="196" height="22" rx="11" fill="none" stroke="${accent}" stroke-width="2"/>`,
    `</svg>`,
  ].join("");
  return `data:image/svg+xml;base64,${btoa(svg)}`;
}

const layer = (id: string, position: number, on: boolean, catalog = true): LookLayer => {
  const seed = seedOf(id);
  return {
    id,
    name: seed?.name ?? id.split("/").pop() ?? id,
    on,
    position,
    source: seed?.repo ?? `github.com/${id}`,
    commit: COMMITS[id] ?? "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c",
    catalog,
  };
};

/** The gallery from its stack (top first): each catalog look's `installed` is its stack row. */
export function relistLooks(stack: readonly LookLayer[]): LooksGallery {
  const ordered = stack.map((row, index) => ({ ...row, position: index + 1 }));
  const looks: Look[] = SEEDS.map(({ colors: _colors, ...seed }) => ({
    ...seed,
    installed: ordered.find((row) => row.id === seed.id) ?? null,
  }));
  return { looks, stack: ordered };
}

/** Nothing installed: the catalog only. */
export function mockLooks(): LooksGallery {
  return relistLooks([]);
}

/** Paper installed and on, Studio installed and off under it, and a setup from outside the catalog. */
export function mockStackedLooks(): LooksGallery {
  return relistLooks([
    layer("manaflow-ai/paper-look", 1, true),
    layer("manaflow-ai/studio-look", 2, false),
    {
      ...layer("someone/terminal-tweaks", 3, true, false),
      name: "Terminal Tweaks",
      source: "github.com/someone/cmux-terminal-tweaks",
    },
  ]);
}

/** The consent card `setup install REPO` answers for a catalog look (what it would change). */
export function mockConsentCard(id: string): LookConsentCard {
  const seed = seedOf(id) ?? SEEDS[0]!;
  const views = id.includes("newtab");
  return {
    setup: {
      id: seed.id,
      name: seed.name,
      description: seed.tagline,
      version: "1.2.0",
      theme: views ? undefined : `${seed.name}.ghostty`,
      settings: views
        ? [{ key: "newTab.layout", value: id.includes("cards") ? "cards" : "threads", replaces: "classic" }]
        : [
            { key: "appearance.metrics.chatTurnGap", value: 14 },
            { key: "appearance.accent", value: seed.colors.dark[3], replaces: "#8e8e93" },
          ],
      files: views
        ? [
            { path: "customize/cmux-app.json", part: "views", replaces: false },
            { path: "styles/newtab.css", part: "styles", replaces: false },
          ]
        : [
            { path: `themes/${seed.name}.ghostty`, part: "themes", replaces: false },
            { path: "styles/chat.css", part: "styles", replaces: false },
          ],
      keybindings: 0,
      actions: views
        ? []
        : [
            {
              name: "toggle-focus-mode",
              kind: "command",
              runs: "cmux settings toggle chat.focusMode",
              replaces: false,
            },
          ],
      extensions: views ? ["github.com/manaflow-ai/cmux-newtab-feed"] : [],
      layer: views ? `local/setup-${seed.id.replace("/", "-")}` : undefined,
    },
    source: {
      reference: seed.repo,
      repository: `https://${seed.repo}`,
      commit: COMMITS[seed.id] ?? "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c",
      page: `https://${seed.repo}`,
      local: false,
    },
    reviewed: false,
    extensions: views
      ? [
          {
            reference: "github.com/manaflow-ai/cmux-newtab-feed",
            app: "newtab-feed",
            installed: false,
            scopes: ["chats:read", "projects:read"],
          },
        ]
      : [],
    undo: `cmux setup remove ${seed.repo}`,
  };
}

/** `setup preview ID --scheme S`: the image, or `setup.preview_missing` for a look with none
 * (`missing` lists those ids). */
export function previewLook(
  id: string,
  scheme: "light" | "dark",
  missing: readonly string[] = [],
): LookPreview | { code: string; message: string } {
  if (missing.includes(id) || !seedOf(id))
    return {
      code: "setup.preview_missing",
      message: `${id} has no preview/golden-${scheme}.png or screenshots/chat.png`,
    };
  return { id, scheme, path: `preview/golden-${scheme}.png`, dataUrl: mockPreviewUrl(id, scheme), cached: true };
}

const repoOf = (reference: string) => reference.replace(/@[^/@]*$/, "");

/** One change verb on the gallery, as the CLI makes it; null with the CLI's error message when it
 * refuses (an id that is not installed, an order that is not every id). An install without `yes`
 * answers the consent card instead (`consent`). */
export function runLooks(
  gallery: LooksGallery,
  run: Exclude<LooksRun, { verb: "gallery" } | { verb: "preview" }>,
): { gallery: LooksGallery } | { consent: LookConsentCard } | { refusal: string } {
  const stack = gallery.stack;
  switch (run.verb) {
    case "install": {
      const repo = repoOf(run.reference);
      const seed = SEEDS.find((one) => one.repo === repo || one.id === repo);
      if (!seed) return { refusal: `no cmux-setup.json in ${repo}` };
      if (!run.yes) return { consent: mockConsentCard(seed.id) };
      const rest = stack.filter((row) => row.id !== seed.id);
      return { gallery: relistLooks([layer(seed.id, 1, true), ...rest]) };
    }
    case "remove": {
      if (!stack.some((row) => row.id === run.id)) return { refusal: `${run.id} is not installed` };
      return { gallery: relistLooks(stack.filter((row) => row.id !== run.id)) };
    }
    case "on":
    case "off": {
      if (!stack.some((row) => row.id === run.id)) return { refusal: `${run.id} is not installed` };
      return {
        gallery: relistLooks(stack.map((row) => (row.id === run.id ? { ...row, on: run.verb === "on" } : row))),
      };
    }
    case "order": {
      const ids = new Set(run.ids);
      if (ids.size !== stack.length || stack.some((row) => !ids.has(row.id)))
        return { refusal: "order takes every installed setup, top first" };
      return { gallery: relistLooks(run.ids.map((id) => stack.find((row) => row.id === id)!)) };
    }
  }
}
