// l10n-allow-file: gallery fixtures (build rows and change titles stand in for the host's), not shipped UI.
// Going back to an earlier build from the Updated card's changes (GoBack.tsx). Leo 2026-11-11:
// reverting the app to the previous nightly was slow, sometimes did not work, and needed a better
// UI. One entry names the build ("Go Back to nightly 4288034 from Nov 10"); "Other builds" opens
// the last few, each with its date and first change. Three looks, `footer` ships.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import type { GoBackLook } from "./GoBack";
import table from "./generated/strings.json";
import type { RecentBuildRow, UpdateHighlights } from "./updateHighlights";
import { UpdatedNotes } from "./UpdatedNotes";

const data: UpdateHighlights = {
  version: "1.0.0-nightly.4291415492601",
  build: "4291415492601",
  fromVersion: "1.0.0-nightly.4288034619601",
  fromBuild: "4288034619601",
  date: "2026-11-11",
  builtAt: "2026-11-11T00:12:40Z",
  head: "23c9f5a8c51b7d2f0e9a4d6b1c3e5f7a9b0d2e4f",
  source: "whatsNew",
  language: "en",
  items: [
    { id: "restart", title: "Restart to Update opens the new build in about a second", summary: null, category: "improved" },
    { id: "composer", title: "The composer keeps its height while a reply streams", summary: null, category: "fixed" },
    { id: "cloud", title: "Cloud chats retry a relay that never opened", summary: null, category: "fixed" },
  ],
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.4288034619601", to: "1.0.0-nightly.4291415492601" },
  goBack: {
    build: "4288034619601",
    label: "nightly 4288034 from Nov 10",
    kept: true,
    title: "Go Back to nightly 4288034 from Nov 10",
  },
};

const builds: RecentBuildRow[] = [
  {
    build: "4291415492601",
    version: "1.0.0-nightly.4291415492601",
    date: "2026-11-11",
    installed: true,
    kept: false,
    switchable: false,
    pulled: false,
    titles: ["Restart to Update opens the new build in about a second"],
  },
  {
    build: "4288034619601",
    version: "1.0.0-nightly.4288034619601",
    date: "2026-11-10",
    installed: false,
    kept: true,
    switchable: true,
    pulled: false,
    titles: ["Sidebar rows keep their place while a chat streams"],
  },
  {
    build: "4285120073301",
    version: "1.0.0-nightly.4285120073301",
    date: "2026-11-10",
    installed: false,
    kept: false,
    switchable: false,
    pulled: true,
    titles: ["Agent pane footer without the slow indicator"],
  },
  {
    build: "4279903318201",
    version: "1.0.0-nightly.4279903318201",
    date: "2026-11-09",
    installed: false,
    kept: false,
    switchable: true,
    pulled: false,
    titles: ["Selected tabs join the content surface"],
  },
];

type State = { kind: "idle" } | { kind: "going"; build?: string } | { kind: "failed"; message: string };

type Props = {
  look: GoBackLook;
  open?: boolean;
  state?: State;
  /** No kept build: the entry is gone and only the list offers a way back (a download). */
  nothingKept?: boolean;
  theme?: "dark" | "light";
};

function GoBackGallery({ look, open, state, nothingKept = false, theme = "dark" }: Props) {
  const [strings] = useState(() => createStrings(table));
  const noop = () => undefined;
  return (
    <div className="wn-gallery-stage" style={{ colorScheme: theme, width: 360, padding: "var(--ds-space-2)" }}>
      <div
        style={{
          // The hover card window beside the sidebar, 340 wide, as UpdatedNotes stands in it.
          width: 340,
          display: "flex",
          flexDirection: "column",
          maxHeight: 460,
          borderRadius: "var(--ds-radius-control)",
          background: "var(--page-elevated)",
          boxShadow: "0 0 0 1px var(--page-separator)",
          overflow: "hidden",
        }}
      >
        <UpdatedNotes
          data={nothingKept ? { ...data, goBack: null } : data}
          strings={strings}
          actions={{
            openChangelog: noop,
            dismiss: noop,
            goBack: async () => null,
            builds: async () => builds,
          }}
          look="sections"
          goBackLook={look}
          goBackFixture={{ builds, open, state }}
        />
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.changelog.go-back",
  title: "Go back to an earlier build",
  area: "Pages",
  covers: ["pages/changelog/GoBack.tsx#GoBack", "pages/changelog/GoBack.tsx#GoBackHeaderLink"],
  load: async () => GoBackGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("./updateSurfaces.css");
  },
  variants: {
    footer: {
      note: "Picked and shipped (Leo 2026-11-11: \"reverting the app to previous nightly is really slow/doesn't work very well sometimes?/needs less [bad] ui\"): one entry at the foot of the Updated card's changes names the build and its day, \"Go Back to nightly 4288034 from Nov 10\", with \"Other builds\" beside it. Chosen over the header link because it says where it goes before the click, and over the open list because the list is rarely needed and would push the changes up. The click quits with every session and opens the kept build; the sidebar's card names each step.",
      props: { look: "footer" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".wn-goback-entry")?.textContent?.includes("Nov 10") === true);
      },
    },
    "footer-open": {
      note: "The shipped look with Other builds open: the last builds, newest first, each with its day and first change. Running marks the build in use; Pulled marks one taken off the feed (no Go back); a build not kept downloads first.",
      props: { look: "footer", open: true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".wn-goback-build").length === builds.length);
      },
    },
    "footer-light": {
      note: "The shipped look in the light theme, list open.",
      props: { look: "footer", open: true, theme: "light" },
    },
    "footer-failed": {
      note: "It did not run: the reason, in place, with what to do (here the kept copy failed its signature check, so the card offers the download).",
      props: {
        look: "footer",
        state: {
          kind: "failed",
          message: "The kept copy of nightly 4288034 no longer passes its signature check. Pick it under Other builds to download it again.",
        },
      },
    },
    "footer-nothing-kept": {
      note: "Nothing kept (an update from before keeping): no entry, Other builds offers the builds the feed still has; going to one downloads and checks it first.",
      props: { look: "footer", open: true, nothingKept: true },
    },
    header: {
      note: "Variant: a quiet \"Go Back\" link on the title's line beside What's New. Compact, but it does not say where it goes until hovered, and there is no room for the list.",
      props: { look: "header" },
    },
    list: {
      note: "Variant: the builds always open, the previous one marked. Every way back at a glance, but the list takes the card's height from the changes it exists to show.",
      props: { look: "list" },
    },
  },
});
