// l10n-allow-file: gallery fixtures (sample processes), not shipped UI.
// The Task Manager page (cmux-page://cmux.task-manager/): the same TaskManagerPage main.tsx mounts, on
// the mock host's snapshot instead of the app's samples. Looks after the app's list pages and
// cmux-design-references aside/web/credential-access-log (a compact table, one row per entry, quiet
// separators) and claude/live/panel-context-breakdown (numbers right-aligned, refused rows quieter).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import {
  firstSampleSnapshot,
  longNamesSnapshot,
  manyRowsSnapshot,
  MockTaskManagerProvider,
  normalSnapshot,
} from "./mockProvider";
import { EMPTY_SNAPSHOT, TaskManagerStore } from "./store";
import { TaskManagerRoot } from "./TaskManagerPage";
import type { SortOrder, TaskManagerSnapshot } from "./types";

type Props = {
  snapshot: TaskManagerSnapshot;
  selected?: string;
  order?: SortOrder;
};

function TaskManagerGallery({ snapshot, selected, order }: Props) {
  const [store] = useState(
    () => new TaskManagerStore(new MockTaskManagerProvider(snapshot), { snapshot, selected, order }),
  );
  const [strings] = useState(() => createStrings(table));
  return <TaskManagerRoot store={store} strings={strings} />;
}

export default componentEntry<Props>({
  id: "pages.task-manager",
  title: "Task Manager",
  area: "Pages",
  height: 560,
  widths: { narrow: 420, normal: 720, wide: 1000 },
  covers: ["page:cmux.task-manager", "pages/task-manager/TaskManagerPage.tsx"],
  load: async () => TaskManagerGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    empty: { note: "The page before the first sample: Reading processes…", props: { snapshot: EMPTY_SNAPSHOT } },
    "first-sample": { note: "One sample in: no CPU until the second.", props: { snapshot: firstSampleSnapshot() } },
    normal: { note: "A working window, in the app's order.", props: { snapshot: normalSnapshot() } },
    "many-rows": {
      note: "Fifty-odd processes, sorted by CPU, highest first; the header stays put.",
      props: { snapshot: manyRowsSnapshot(), order: { key: "cpu", ascending: false } },
    },
    "selected-killable": {
      note: "A terminal's process selected: Kill Process is on.",
      props: { snapshot: normalSnapshot(), selected: "local:734" },
    },
    "selected-refused": {
      note: "The app itself selected: the policy refuses it, so Kill Process is off (its reason is the tooltip).",
      props: { snapshot: normalSnapshot(), selected: "local:501" },
    },
    "remote-selected": {
      note: "Another machine's process: shown as host:pid, never ended from here.",
      props: { snapshot: manyRowsSnapshot(), selected: "m-cloud:4242", order: { key: "pid", ascending: false } },
    },
    "long-names": {
      note: "Long tab titles and executables, and a remote machine with a long id: at the narrow width the table scrolls sideways so Task and Process stay readable, and the host gives way before the pid.",
      props: { snapshot: longNamesSnapshot(), selected: "devbox-eu-west-build-07:918273" },
    },
  },
});
