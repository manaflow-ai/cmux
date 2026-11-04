// l10n-allow-file: deterministic, public-safe gallery chat fixtures.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AllChatsList, AllChatsPage } from "./AllChatsList";

const props = { onOpen: () => undefined, now: 1_800_000_000_000 };
const pending = () => new Promise<AllChatsPage>(() => {});
const chats = Array.from({ length: 6 }, (_, index) => ({
  key: `codex:loading-example-${index}`,
  harness: "codex",
  title: [
    "Review the settings",
    "Fix a loading state",
    "Update the docs",
    "Check keyboard focus",
    "Inspect the build",
    "Tidy the tests",
  ][index],
  updatedAt: props.now - (index + 1) * 60_000,
}));

export default componentEntry<ComponentProps<typeof AllChatsList>>({
  id: "agent-pane.all-chats-loading",
  title: "All chats loading",
  area: "Agent pane",
  covers: ["agent-session/acpmux/newtab/AllChatsList.tsx#AllChatsList"],
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  load: () => import("./AllChatsList").then((module) => module.AllChatsList),
  widths: { narrow: 320, normal: 620, wide: 820 },
  height: 300,
  anchors: [{ selector: ".nt-all" }],
  variants: {
    "first-page": {
      note: "The first read is pending; static rows occupy the loaded row layout.",
      props: { ...props, load: pending },
    },
    indexing: {
      note: "The first reply is empty but the daemon has not completed its index scan.",
      props: { ...props, load: async () => ({ chats: [], ready: false }) },
    },
    loaded: {
      note: "Six public sample chats at the same row height as the loading placeholders.",
      props: { ...props, load: async () => ({ chats, ready: true }) },
    },
    empty: {
      note: "A completed empty read keeps the existing empty state.",
      props: { ...props, load: async () => ({ chats: [], ready: true }) },
    },
    failed: {
      note: "A failed read keeps the existing error and Try again action.",
      props: { ...props, load: async () => undefined },
    },
  },
});
