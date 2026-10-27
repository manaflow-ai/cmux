// l10n-allow-file: gallery fixtures use sample chat rows and a deterministic page cursor.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComponentProps } from "react";
import { AllChatsList, type AllChatsPage, type LoadChatsPage } from "./AllChatsList";

const rows = Array.from({ length: 8 }, (_, index) => ({
  key: `claude:gallery-${index}`,
  harness: "claude",
  title: index === 0 ? "Recover a failed history page" : `Earlier chat ${index}`,
  cwd: "/Users/you/src/cmux",
  updatedAt: Date.now() - index * 60_000,
}));

const first: AllChatsPage = { chats: rows, nextCursor: "page-2", ready: true, design: "age" };
const second: AllChatsPage = {
  chats: [
    {
      key: "claude:gallery-older",
      harness: "claude",
      title: "An older recovered chat",
      cwd: "/Users/you/src/cmux",
      updatedAt: Date.now() - 12 * 60_000,
    },
  ],
  ready: true,
};

const baseProps = {
  onOpen: () => undefined,
  onOpenInTerminal: () => undefined,
};

const waitForRetry = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-chats-retry") !== null);
};

const pageLoad = (failed: boolean): LoadChatsPage => async ({ cursor }) => {
  if (!cursor) return first;
  return failed ? undefined : second;
};

export default componentEntry<ComponentProps<typeof AllChatsList>>({
  id: "agent-pane.all-chats-list",
  title: "All chats page recovery",
  area: "Agent pane",
  covers: ["agent-session/acpmux/newtab/AllChatsList.tsx#AllChatsList"],
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  load: () => import("./AllChatsList").then((module) => module.AllChatsList),
  widths: { narrow: 420, normal: 620, wide: 820 },
  height: 360,
  anchors: [{ selector: ".nt-all" }],
  variants: {
    "page-failed": {
      note: "When an older history page fails, the cursor stays in place and the loader becomes an inline Try again action.",
      props: { ...baseProps, load: pageLoad(true) },
      play: waitForRetry,
    },
    "page-recovered": {
      note: "Retrying the same older page appends its chats and removes the recovery row.",
      props: { ...baseProps, load: pageLoad(false) },
    },
    "page-empty": {
      note: "A first page with no cursor stays a quiet list with no dead loader row.",
      props: { ...baseProps, load: async () => ({ chats: rows, ready: true }) },
    },
  },
});
