// l10n-allow-file: public gallery sample paths and design notes, not shipped UI.
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";

const chipHost: ChipHostFixture = {
  paths: {
    "/example/project/cmux.json": { place: "root", folder: false },
    "/example/project/src/": { place: "root", folder: true },
    "/example/project/src/config.ts:42": { place: "root", folder: false },
    "/example/project/src/configuration/resolve-project-settings.ts": { place: "root", folder: false },
    "/tmp/example/notes.md": { place: "outside", folder: false },
  },
  policy: { outsideRoots: "confirm" },
};

export default componentEntry<{ variant: string }>({
  id: "agent-pane.inline-chips",
  title: "Inline reference chips",
  area: "Agent pane",
  height: 280,
  widths: { narrow: 320, normal: 640, wide: 860 },
  covers: [
    "agent-session/acpmux/chips/LinkChips.tsx#PathChip",
    "agent-session/acpmux/chips/LinkChips.tsx#UrlChip",
    "agent-session/acpmux/chips/LinkChips.tsx#ElsewhereChip",
  ],
  load: () => import("../../../gallery/fixtures/InlineChipsPreview").then((module) => module.InlineChipsPreview),
  styles: () =>
    Promise.all([
      import("../../shared/styles.css"),
      import("../conversation/conversation.css"),
      import("./chips.css"),
      import("../../../gallery/fixtures/inlineChips.gallery.css"),
    ]),
  variants: {
    before: {
      chipHost,
      props: { variant: "before" },
      note: "Historical padding, weight and fill. Compare with after-minimal in both light and dark themes.",
    },
    "after-minimal": {
      chipHost,
      props: { variant: "minimal" },
      note: "Recommended: prose-sized regular text, tinted icons and no box or padding. Hover an outside path for its locality.",
    },
    "after-accent": {
      chipHost,
      props: { variant: "accent" },
      note: "Alternative: also tint file labels with the link color. Available in light/dark and narrow widths.",
    },
    "after-hairline": {
      chipHost,
      props: { variant: "hairline" },
      note: "Alternative: a hairline drawn inside the reference without changing its line metrics.",
    },
  },
});
