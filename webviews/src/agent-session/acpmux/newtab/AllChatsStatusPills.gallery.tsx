// l10n-allow-file: gallery fixtures use sample chat rows.
// Status Pills in All Chats (Taste Board #19, `agentPane.display.chatListStatusPills`): the same
// list with the setting off (today's rows) and on (a pill on each live chat that is not idle).
import { useLayoutEffect, type ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import { CHAT_LIST_STATUS_PILLS_KEY, setChatDisplay } from "../chatDisplay";
import type { ActiveChat, AllChatsList } from "./AllChatsList";
import type { AllChatsPage } from "./allChatsListModel";

type Props = ComponentProps<typeof AllChatsList> & { pills: boolean };

const page: AllChatsPage = {
  chats: [
    {
      key: "claude:pill-1",
      harness: "claude",
      title: "Audit the invoice exports",
      cwd: "/Users/you/src/atlas",
      updatedAt: minutesAgo(40),
    },
    {
      key: "codex:pill-2",
      harness: "codex",
      title: "Tidy the retry policy",
      cwd: "/Users/you/src/atlas",
      updatedAt: minutesAgo(180),
    },
    {
      key: "claude:pill-3",
      harness: "claude",
      title: "Release notes draft",
      cwd: "/Users/you/src/site",
      updatedAt: minutesAgo(26 * 60),
    },
  ],
  ready: true,
  design: "age",
};

const active: ActiveChat[] = [
  {
    id: "pill-running",
    title: "Migrate saved payment methods to the new vault",
    harness: "claude",
    state: "running",
    label: "Running",
  },
  { id: "pill-input", title: "Rename the settings rows", harness: "codex", state: "input", label: "Needs input" },
  { id: "pill-unread", title: "Profile the cold start", harness: "claude", state: "unread", label: "Unread" },
  { id: "pill-failed", title: "Bump the toolchain", harness: "codex", state: "failed", label: "Failed" },
  { id: "pill-error", title: "Sync the fixtures", harness: "claude", state: "error", label: "Disconnected" },
];

const leads: ActiveChat[] = [
  { id: "pill-lead", title: "coordinator", harness: "claude", state: "running", label: "4 reporting" },
  { id: "pill-lead-idle", title: "area-owner", harness: "claude", state: "idle", label: "2 reporting" },
];

const base = {
  load: async () => page,
  onOpen: () => undefined,
  onOpenActive: () => undefined,
  active,
  leads,
  now: GALLERY_NOW,
};

export default componentEntry<Props>({
  id: "agent-pane.all-chats-status-pills",
  title: "All chats status pills",
  area: "Agent pane",
  covers: ["agent-session/acpmux/newtab/AllChatsList.tsx#AllChatsList"],
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  load: () =>
    import("./AllChatsList").then(({ AllChatsList: List }) => {
      function StatusPillsDemo({ pills, ...props }: Props) {
        useLayoutEffect(() => {
          setChatDisplay(pills ? { [CHAT_LIST_STATUS_PILLS_KEY]: true } : {});
          return () => setChatDisplay({});
        }, [pills]);
        return <List {...props} />;
      }
      return StatusPillsDemo;
    }),
  widths: { narrow: 420, normal: 620, wide: 820 },
  height: 420,
  anchors: [{ selector: ".nt-all" }],
  variants: {
    off: {
      note: "Setting off (the default): live chats show their state as plain text, as before.",
      props: { ...base, pills: false },
    },
    on: {
      note: "Status Pills in All Chats on: Running, Needs you, Done and Failed as small pills; a leader keeps its count with the pill after it; idle and indexed rows show none.",
      props: { ...base, pills: true },
    },
  },
});
