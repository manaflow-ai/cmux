// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { TasksFixtureState } from "./galleryFixture";
import type { Layout, Scope } from "./types";

type Props = { layout?: Layout; state?: TasksFixtureState; scope?: Scope };

export default componentEntry<Props>({
  id: "pages.tasks",
  title: "Tasks",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["page:cmux.tasks", "pages/tasks/TasksPage.tsx", "pages/tasks/Glyphs.tsx", "pages/tasks/galleryFixture.tsx"],
  load: async () => (await import("./galleryFixture")).TasksGallery,
  styles: async () => {
    await import("../../ui/ui.css");
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    inbox: {
      note: "Default layout (tasks.layout inbox): waiting, review and failed first, the selected task's agent session and plan on the right.",
      props: { layout: "inbox" },
    },
    list: { note: "Layout list: dense rows grouped by status in workflow order.", props: { layout: "list" } },
    board: {
      note: "Layout board: a column per status; dropping a card on a column changes its status.",
      props: { layout: "board" },
    },
    mine: {
      note: "My Tasks: the scope bar names the scope and Show All widens it.",
      props: { layout: "list", scope: "mine" },
    },
    pending: {
      note: "A status change and a new task show at once, dimmed until the owner confirms them.",
      props: { layout: "list", state: "pending" },
    },
    rejected: {
      note: "The owner refused an archive: the row is back and the reason shows under the field.",
      props: { layout: "list", state: "rejected" },
    },
    "owner-missing": {
      note: "No Tasks owner answers: the command that starts it, with Copy.",
      props: { state: "owner-missing" },
    },
    "owner-lost": {
      note: "The owner went away after the first snapshot: the rows stay, a banner says so.",
      props: { layout: "list", state: "owner-lost" },
    },
    empty: { note: "No tasks yet.", props: { layout: "list", state: "empty" } },
    "many-list": { note: "411 tasks: the list is virtualized.", props: { layout: "list", state: "many" } },
    "many-board": {
      note: "411 tasks across the board's columns, each column virtualized.",
      props: { layout: "board", state: "many" },
    },
  },
});
