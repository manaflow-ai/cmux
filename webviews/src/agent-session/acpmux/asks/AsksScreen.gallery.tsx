// l10n-allow-file: gallery fixtures, public-safe sample asks, chats and repositories.
// Your asks (History > Your asks, AsksScreen.tsx): what the person typed into chats on this
// machine, newest first, each with its chat, the pull requests whose body names it and its status;
// and the states a person can meet: nothing asked yet, a failed read, and an older acpmux.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AsksScreen } from "./AsksScreen";

type Props = ComponentProps<typeof AsksScreen>;

const MINUTE = 60_000;
const NOW = Date.UTC(2026, 10, 18, 15);

const ask = (
  id: string,
  minutesAgo: number,
  text: string,
  harness: string,
  sessionTitle: string,
  status: string,
  prs: unknown[] = [],
) => ({
  id,
  ts: NOW - minutesAgo * MINUTE,
  text,
  harness,
  sessionId: `chat-${id}`,
  sessionTitle,
  host: "studio",
  messageId: `p-${id}`,
  status,
  prs,
});

const pr = (number: number, state: string) => ({
  url: `https://github.com/acme/widgets/pull/${number}`,
  repo: "acme/widgets",
  number,
  state,
});

const asks = [
  ask(
    "ask-3f9a1c02d4",
    4,
    "Add a list of everything I asked, linked to the chats and PRs",
    "claude",
    "Ask ledger",
    "open",
  ),
  ask("ask-81be22a0c7", 52, "Make the sidebar remember its width per window", "codex", "Sidebar width", "pr", [
    pr(4120, "open"),
  ]),
  ask(
    "ask-0d4471e9b3",
    3 * 60,
    "Fix the crash when a chat is closed while its turn streams\nIt happens about once a day.",
    "claude",
    "Close while streaming",
    "merged",
    [pr(4098, "closed"), pr(4101, "merged")],
  ),
  ask("ask-c6e5f0a118", 26 * 60, "Why does the build take four minutes now?", "codex", "Build time", "open"),
];

const base: Props = {
  load: async () => ({ asks, host: "studio" }),
  openSession: () => undefined,
  openUrl: () => undefined,
  now: NOW,
};

export default componentEntry<Props>({
  id: "agent-pane.your-asks",
  title: "Your asks",
  area: "Agent pane",
  covers: ["agent-session/acpmux/asks/AsksScreen.tsx#AsksScreen"],
  styles: () => Promise.all([import("../styles.css"), import("./asks.css")]),
  load: () => import("./AsksScreen").then((module) => module.AsksScreen),
  widths: { narrow: 380, normal: 720, wide: 960 },
  height: 420,
  anchors: [{ selector: ".ask" }],
  variants: {
    loaded: {
      note: "Newest first: an open ask, one with an open pull request, one whose second pull request merged, and an older open one.",
      props: base,
    },
    empty: {
      note: "Nothing typed into a chat yet.",
      props: { ...base, load: async () => ({ asks: [], host: "studio" }) },
    },
    error: {
      note: "The read failed: the status says so and offers Try again.",
      props: { ...base, load: async () => Promise.reject(new Error("timeout")) },
    },
    older: {
      note: "An acpmux that keeps no asks yet answers method not found.",
      props: {
        ...base,
        load: async () => Promise.reject(Object.assign(new Error("Method not found"), { code: -32601 })),
      },
    },
  },
});
