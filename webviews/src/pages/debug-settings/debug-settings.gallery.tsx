// l10n-allow-file: gallery fixtures (sample tunables), not shipped UI.
// Debug Settings (cmux-page://cmux.debug-settings/): the same page main.tsx mounts, over the
// in-memory provider with sample tunables of every control kind (including the omnibar glass
// knobs), so new kinds and states show without the app.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { UiProvider } from "../../ui/UiProvider";
import { createStrings } from "../shared/i18n";
import { DebugSettingsPage } from "./DebugSettingsPage";
import table from "./generated/strings.json";
import { MockDebugTunablesProvider } from "./mockProvider";
import { DebugSettingsStore } from "./store";
import type { TunableValue } from "./types";

type Props = {
  overrides?: Record<string, TunableValue>;
  selection?: string;
  query?: string;
  offline?: boolean;
  noHangs?: boolean;
};

function DebugSettingsGallery({
  overrides = {},
  selection = "all",
  query = "",
  offline = false,
  noHangs = false,
}: Props) {
  const [store] = useState(() => {
    const provider = new MockDebugTunablesProvider(undefined, undefined, overrides);
    provider.selection = selection;
    provider.query = query;
    provider.offline = offline;
    if (noHangs) provider.hangs = { ...provider.hangs, items: [] };
    return new DebugSettingsStore(provider, { writeClipboard: async () => {} });
  });
  const [strings] = useState(() => createStrings(table));
  const [root, setRoot] = useState<HTMLDivElement | null>(null);
  return (
    <div ref={setRoot} style={{ height: "100%" }}>
      {root ? (
        <UiProvider container={root}>
          <DebugSettingsPage store={store} strings={strings} />
        </UiProvider>
      ) : null}
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.debug-settings",
  title: "Debug Settings",
  area: "Pages",
  height: 640,
  widths: { narrow: 360, normal: 1000, wide: 1400 },
  covers: [
    "page:cmux.debug-settings",
    "pages/debug-settings/DebugSettingsPage.tsx#DebugSettingsPage",
    "pages/debug-settings/TunableControl.tsx#TunableControlView",
    "pages/debug-settings/DebugSettingsPage.tsx#HangsCard",
  ],
  load: async () => DebugSettingsGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    normal: { note: "Every tunable, one row per control kind, nothing changed.", props: {} },
    changed: {
      note: "Two omnibar glass knobs and a spring differ from their defaults; the Changed list is shown.",
      props: {
        selection: "changed",
        overrides: {
          "browser.omnibar.glass.tint": 0.4,
          "browser.omnibar.glass.shadow": false,
          "motion.spring.move": { response: 0.5, dampingFraction: 0.7 },
        },
      },
    },
    section: {
      note: "The Browser section with the omnibar glass design and its live knobs.",
      props: { selection: "browser" },
    },
    search: { note: "A search across every section.", props: { query: "omnibar" } },
    hangs: {
      note: "Debug Settings > Hangs: the hang-file toggle and the recent hangs, one the app came back from and one it was killed in.",
      props: { selection: "hangs" },
    },
    "hangs-empty": {
      note: "Hangs with no hang file recorded yet.",
      props: { selection: "hangs", noHangs: true },
    },
    "nothing-changed": {
      note: "The Changed list when every tunable has its default.",
      props: { selection: "changed" },
    },
    disconnected: { note: "The app does not answer.", props: { offline: true } },
    narrow: {
      note: "The Browser section; at the narrow width (cx-bbe2) labels sit above their controls and the sections form a strip above the list.",
      props: { selection: "browser" },
    },
    "toggle-live": {
      note: "A switch click applies at once: the row shows as changed and Reset All turns on.",
      props: { selection: "browser" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('[data-testid="ds.control.browser.omnibar.glass.shadow"]'));
        // At the narrow width the row is below the fold; a person scrolls to it first.
        ctx.document
          .querySelector('[data-testid="ds.control.browser.omnibar.glass.shadow"]')
          ?.scrollIntoView({ block: "center" });
        await ctx.click({ selector: '[data-testid="ds.control.browser.omnibar.glass.shadow"]' });
        await ctx.waitFor(() =>
          ctx.document.querySelector('[data-testid="ds.row.browser.omnibar.glass.shadow"][data-changed="true"]'),
        );
        await ctx.waitFor(
          () => !ctx.document.querySelector<HTMLButtonElement>('[data-testid="ds.resetAll"]')?.disabled,
        );
      },
    },
  },
});
