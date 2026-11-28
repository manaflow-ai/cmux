// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { ForumGalleryProps } from "./galleryFixture";

// Three layouts of the same parts (ForumPage.tsx): A columns, B split, C stream. Each has the same
// states so they compare row by row; the rest are the page's states on the recommended layout (A).
export default componentEntry<ForumGalleryProps>({
  id: "pages.forum",
  title: "Forum",
  area: "Pages",
  experimental: true,
  height: 640,
  widths: { narrow: 420, normal: 1000, wide: 1400 },
  keywords: ["agent forum", "threads", "questions", "board"],
  covers: ["pages/forum/ForumPage.tsx#ForumPage", "pages/forum/galleryFixture.tsx"],
  load: async () => (await import("./galleryFixture")).ForumGallery,
  styles: async () => {
    await import("../../ui/ui.css");
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    "a-columns": {
      note: "A (recommended): spaces in a rail, the thread list, the open thread with its reply box. A mail client's three columns.",
      props: { layout: "columns", thread: 41 },
    },
    "b-split": {
      note: "B: spaces as tabs above the list (the History and Stash header), the open thread on the right.",
      props: { layout: "split", thread: 41 },
    },
    "c-stream": {
      note: "C: one column; a thread opens in place under its row. For a narrow pane or the agent column.",
      props: { layout: "stream", thread: 41 },
    },
    "a-new-thread": {
      note: "A with New Thread open: space, kind, title and body; Post sends it as you.",
      props: { layout: "columns", thread: 41, composer: "new" },
    },
    "b-new-thread": { note: "B with New Thread open.", props: { layout: "split", thread: 41, composer: "new" } },
    "c-new-thread": { note: "C with New Thread open.", props: { layout: "stream", composer: "new" } },
    "a-answered": {
      note: "A on an answered finding: the agent's post links back to its chat (Open Chat).",
      props: { layout: "columns", thread: 40 },
    },
    "a-many": {
      note: "A with thirty threads, long titles, the feed catching up.",
      props: { layout: "columns", data: "many", thread: 41 },
    },
    "c-many": { note: "C with thirty threads.", props: { layout: "stream", data: "many" } },
    "a-space": { note: "A filtered to one space.", props: { layout: "columns", space: "fleet", thread: 41 } },
    "a-search": { note: "A with a search.", props: { layout: "columns", query: "linker", thread: 41 } },
    "a-no-match": { note: "A with a search that matches nothing.", props: { layout: "columns", query: "zzz" } },
    "a-empty": { note: "A team with no threads yet.", props: { layout: "columns", data: "empty" } },
    "a-offline": {
      note: "The last feed pull failed: the cached threads stay, the badge says Offline.",
      props: { layout: "columns", data: "offline", thread: 41 },
    },
    off: { note: "The forum is not on for this team.", props: { data: "off" } },
    "signed-out": { note: "Not signed in.", props: { data: "signed-out" } },
    loading: { note: "The first snapshot has not arrived.", props: { data: "loading" } },
  },
});
