// l10n-allow-file: gallery prototype fixtures, not shipped UI.
// The not-ready App Store, four ways (Beyer, Nov 20: "don't show the app store until it's ready, it
// takes too much space"). The sidebar is native, so the prototype draws a copy of it; the shipped
// gating (labs.previewFeatures) is unchanged.
import { componentEntry } from "../../gallery/format";
import type { AppStorePresentationProps } from "./AppStorePresentation";

export default componentEntry<AppStorePresentationProps>({
  id: "prototypes.app-store-presentation",
  title: "App Store before it is ready: hidden, coming soon, Labs, New Tab",
  area: "Sidebar",
  experimental: true,
  keywords: ["app store", "labs", "preview", "beyer", "sidebar", "new tab", "coming soon"],
  covers: ["prototypes/app-store/AppStorePresentation.tsx"],
  load: () => import("./AppStorePresentation").then((module) => module.AppStorePresentation),
  height: 580,
  widths: { narrow: 860, normal: 860, wide: 860 },
  variants: {
    hidden: {
      note: "(a) Shipped default, Labs off: no App Store anywhere. What a new user sees.",
      props: {
        variant: "hidden",
        caption:
          "(a) Hidden. Today's default with Show Preview Features off: no row, no tile, no Cmd-1..9 slot, no palette entry.",
      },
    },
    "coming-soon": {
      note: "(b) One faint footer line; no row in the list; clicking it does nothing yet.",
      props: {
        variant: "coming-soon",
        caption:
          "(b) Coming soon. One 22 pt footer line at the bottom of the sidebar; the list starts at Chief as in (a).",
      },
    },
    labs: {
      note: "(c) A full row with a Labs badge; a click offers a one-tap enable.",
      props: {
        variant: "labs",
        enableOpen: true,
        caption:
          "(c) Labs badge. The row stays in its slot, marked Labs; a click opens this card and Turn On sets Show Preview Features.",
      },
    },
    "labs-closed": {
      note: "(c) at rest: the row and its badge, card closed.",
      props: { variant: "labs" },
    },
    "new-tab": {
      note: "(d) Redirect: no sidebar row; the store is an Apps section on the New Tab page.",
      props: {
        variant: "new-tab",
        caption:
          "(d) New Tab section. The sidebar is as in (a); the store shows as an Apps section under the composer, marked Preview.",
      },
    },
  },
});
