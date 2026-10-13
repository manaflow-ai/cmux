// l10n-allow-file: gallery fixtures (public-safe release notes from release-notes/next/highlights), not shipped UI.
// The Updated card and the update-ready highlights (cx-urd.61) on the app theme, at sidebar width.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import type { UpdateHighlights } from "./updateHighlights";
import { UpdatedCard, UpdateReadyHighlights } from "./UpdateSurfaces";

const base: UpdateHighlights = {
  version: "1.0.0-nightly.414",
  build: "3720357960414",
  fromVersion: "1.0.0-nightly.410",
  fromBuild: "3720357960410",
  date: "2026-10-12",
  source: "whatsNew",
  language: "en",
  items: [
    {
      id: "workspace-groups",
      title: "Workspace groups you can see at a glance",
      summary: "Colored labels, icons, and pins that keep a group.",
      category: "new",
    },
    {
      id: "undo-tab-close",
      title: "Undo a tab close from a toast",
      summary: "One click or ⌘Z brings the tabs back.",
      category: "new",
    },
    {
      id: "restart-instant",
      title: "Restart to Update reacts at once",
      summary: "Terminals and agents keep running.",
      category: "improved",
    },
  ],
  moreCount: 6,
  changelog: { from: "1.0.0-nightly.410", to: "1.0.0-nightly.414" },
};

type Props = { surface: "card" | "popover"; data: UpdateHighlights; share?: boolean };

function UpdateSurfacesGallery({ surface, data, share = true }: Props) {
  const [strings] = useState(() => createStrings(table));
  const noop = () => undefined;
  return (
    <div className="wn-gallery-stage" style={{ width: surface === "card" ? 260 : 320, padding: 10 }}>
      {surface === "card" ? (
        <UpdatedCard
          data={data}
          strings={strings}
          actions={{ openChangelog: noop, dismiss: noop, share: share ? noop : undefined }}
        />
      ) : (
        <div
          style={{ borderRadius: 12, background: "var(--page-elevated)", boxShadow: "0 0 0 1px var(--page-separator)" }}
        >
          <UpdateReadyHighlights data={data} strings={strings} actions={{ openChangelog: noop }} />
        </div>
      )}
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.changelog.update-surfaces",
  title: "Updated card and update-ready highlights",
  area: "Pages",
  covers: [
    "pages/changelog/UpdateSurfaces.tsx#UpdatedCard",
    "pages/changelog/UpdateSurfaces.tsx#UpdateReadyHighlights",
  ],
  load: async () => UpdateSurfacesGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("./updateSurfaces.css");
  },
  variants: {
    card: {
      note: "Card A (Note): after an update, the lead change as the headline, the count of the rest.",
      props: { surface: "card", data: base },
    },
    "card-one-change": {
      note: "An update with one listed change: no count line.",
      props: { surface: "card", data: { ...base, items: base.items.slice(0, 1), moreCount: 0 } },
    },
    "card-no-highlights": {
      note: "An update whose notes list nothing (source none): a plain line, the button stays.",
      props: { surface: "card", data: { ...base, source: "none", items: [], moreCount: 0 } },
    },
    "card-long-title": {
      note: "A long localized headline clamps to two lines.",
      props: {
        surface: "card",
        data: {
          ...base,
          items: [
            {
              ...base.items[0]!,
              title: "Agents can use the cmux browser and computer use, with matching skills for Claude Code",
            },
          ],
        },
      },
    },
    popover: {
      note: "Popover A, only what the Update Ready card lacks (Leo 2026-10-13): the full build, the top three changes numbered, +N more, See all changes once.",
      props: { surface: "popover", data: base },
    },
    "popover-titles-only": {
      note: "Summary-line source: titles without a second line.",
      props: {
        surface: "popover",
        data: {
          ...base,
          source: "summary",
          date: null,
          moreCount: 0,
          items: base.items.map((i) => ({ ...i, summary: null })),
        },
      },
    },
    "popover-empty": {
      note: "No highlights (source none): the full build and See all changes only.",
      props: { surface: "popover", data: { ...base, source: "none", items: [], moreCount: 0 } },
    },
  },
});
