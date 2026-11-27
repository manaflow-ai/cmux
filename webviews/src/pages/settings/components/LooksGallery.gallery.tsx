// l10n-allow-file: gallery fixtures (sample looks, consent cards and a refusal), not shipped UI.
// Settings > Appearance > Looks: the catalog's layouts side by side for the pick (rulebook: 3+
// versions), each in every state: the catalog with nothing installed, previews still on their way,
// a look with no preview, two installed and stacked (one off) with a setup from outside the gallery,
// the consent card an Install opens, an install running, the uninstall question, a refusal, an empty
// catalog and a host whose CLI could not read it.
// References (cmux-design-references): codex/web/themes-side-by-side (looks shown as themselves,
// side by side), codex/web/skills-library (installable things with one button each), claude/live/
// settings-session-workflows (one text column, controls on one trailing edge).
// Shipped: `grid`. Every look is its own golden sample at one size, so they compare side by side on
// equal terms, and the grid fits four to eight looks without a scroll. `hero` shows the first look
// best but ranks it over the others for no reason the person gave. `list` fits the most in the least
// height but its small previews hide what tells looks apart.
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { LookPreview, LooksGallery } from "../ops";
import type { LooksLayout } from "./LooksGalleryCard";

type State =
  | "catalog"
  | "loading"
  | "missing"
  | "stacked"
  | "consent"
  | "installing"
  | "remove"
  | "refused"
  | "empty"
  | "unavailable";
type Props = { layout: LooksLayout; state: State; scheme: "light" | "dark" };

const REFUSAL = "github.com/manaflow-ai/cmux-paper-look did not answer: the network is offline";

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { LooksGalleryView } = await import("./LooksGalleryCard");
  const { mockConsentCard, mockLooks, mockStackedLooks, previewLook } = await import("../mockLooks");
  const galleries: Record<State, LooksGallery | null> = {
    catalog: mockLooks(),
    loading: mockLooks(),
    missing: mockLooks(),
    stacked: mockStackedLooks(),
    consent: mockLooks(),
    installing: mockLooks(),
    remove: mockStackedLooks(),
    refused: mockStackedLooks(),
    empty: { looks: [], stack: [] },
    unavailable: null,
  };
  const consent = mockConsentCard("manaflow-ai/newtab-cards-look");
  const actions = { onInstall: () => {}, onToggle: () => {}, onMove: () => {}, onRemove: () => {} };
  const answer =
    (state: State) =>
    async (id: string, scheme: "light" | "dark"): Promise<LookPreview | null> => {
      if (state === "loading") return new Promise<LookPreview | null>(() => {});
      const found = previewLook(id, scheme, state === "missing" ? ["manaflow-ai/newtab-threads-look"] : []);
      return "dataUrl" in found ? found : null;
    };
  return function LooksGalleryLayouts({ layout, state, scheme }: Props) {
    // A client per capture: the tiles' preview reads start fresh, so `loading` stays waiting.
    const [client] = useState(() => new QueryClient({ defaultOptions: { queries: { retry: false } } }));
    const gallery = galleries[state];
    return (
      <QueryClientProvider client={client}>
        <section className="settings-page" style={{ padding: 16 }} data-scheme={scheme}>
          <LooksGalleryView
            gallery={gallery}
            layout={layout}
            scheme={scheme}
            loadPreview={answer(state)}
            busy={state === "installing" ? consent.setup.id : null}
            consent={state === "consent" || state === "installing" ? consent : null}
            removing={state === "remove" ? (gallery?.stack[0] ?? null) : null}
            refusal={state === "refused" ? REFUSAL : null}
            actions={actions}
            onConfirmInstall={() => {}}
            onCancelInstall={() => {}}
            onConfirmRemove={() => {}}
            onCancelRemove={() => {}}
          />
        </section>
      </QueryClientProvider>
    );
  };
}

const LAYOUTS: Record<LooksLayout, string> = {
  grid: "Shipped: equal tiles, each its golden sample over its name, tagline and Install",
  hero: "The first look large over a rail of the rest",
  list: "One compact row per look with a small preview",
};
const STATES: Record<State, string> = {
  catalog: "the catalog, nothing installed, every preview drawn",
  loading: "previews still on their way: each tile holds its frame, so nothing moves when they land",
  missing: "New Tab Threads' repo has no preview image",
  stacked: "Paper on and Studio off, stacked under the gallery with a setup from outside it",
  consent: "Install on New Tab Cards: the consent card lists its settings, views, stylesheet and extension scopes",
  installing: "Install confirmed: the install runs and every control waits",
  remove: "Uninstall on Paper asks first, inline",
  refused: "a change the CLI refused: its words under the gallery",
  empty: "a catalog with no looks",
  unavailable: "the CLI could not read the gallery",
};

const variants: Record<string, { note: string; props: Props }> = {};
for (const layout of Object.keys(LAYOUTS) as LooksLayout[]) {
  for (const state of Object.keys(STATES) as State[]) {
    variants[`${layout}-${state}`] = {
      note: `${LAYOUTS[layout]}; ${STATES[state]}.`,
      props: { layout, state, scheme: "dark" },
    };
  }
  variants[`${layout}-catalog-light`] = {
    note: `${LAYOUTS[layout]}; the catalog in light: each tile asks for its light golden sample.`,
    props: { layout, state: "catalog", scheme: "light" },
  };
}

export default componentEntry<Props>({
  id: "settings.looks-gallery-layouts",
  title: "Looks gallery layouts",
  area: "Settings",
  height: 720,
  widths: { narrow: 420, normal: 720, wide: 980 },
  covers: [
    "pages/settings/components/LooksGalleryCard.tsx#LooksGalleryView",
    "pages/settings/components/LooksGalleryCard.tsx#LooksCatalog",
    "pages/settings/components/LooksGalleryCard.tsx#LookTile",
    "pages/settings/components/LooksGalleryCard.tsx#StackedLooks",
  ],
  load,
  styles: () => import("../page.css"),
  variants,
});
