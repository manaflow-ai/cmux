// l10n-allow-file: gallery fixtures (sample transcripts and titles), not shipped UI.
//
// Opening another chat (chatSwitch.ts): compare arms plays the `chat-switch-motion` experiment's
// four arms side by side. Setup opens Session Info; the script switches to a second chat and back,
// the second switch landing mid-motion to show the play is interruptible.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";
import { chatSwitchMotion } from "./chatSwitch.experiment";

const first = chat(
  [
    user("Why does the build cache miss on CI?", 30),
    assistant(
      "The cache key hashes the whole lockfile, and CI rewrites it on install. Keying on the resolved versions keeps hits across those rewrites.",
      29,
    ),
    user("Can you make that change and check a run?", 20),
    assistant(
      "Done: the key now reads the resolved versions. The last two CI runs restored the cache in 4 s instead of rebuilding for 3 min.",
      18,
    ),
  ],
  { title: "Why does the build cache miss on CI?" },
);

const SECOND = "gallery-session-switch";
function secondChat(): AcpmuxSnapshot {
  const base = chat(
    [
      user("Profile the transcript scroll jank on long chats.", 12),
      assistant(
        "The scroll handler read the composer's height on every wheel event, forcing a layout right after the virtualizer moved its rows.",
        11,
      ),
      user("Fix it and add a test.", 8),
      assistant(
        "Fixed: the height is read once per frame from the resize observer, and a test counts long frames while scrolling a 2,000-message fixture.",
        6,
      ),
      user("Does the minimap still line up?", 3),
      assistant("Yes: its ticks follow the same layout, and the gallery's rail case is unchanged.", 2),
    ],
    { title: "Profile the transcript scroll jank", harness: "codex", model: "gpt-6-astra" },
  );
  return {
    ...base,
    sessionId: SECOND,
    summary: { ...base.summary!, sessionId: SECOND },
    sessions: [{ ...base.sessions[0]!, sessionId: SECOND }, ...first.sessions],
  };
}

type Bridge = { cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void } };
const deliver = (ctx: Parameters<Play>[0], snapshot: AcpmuxSnapshot) =>
  (ctx.document.defaultView as unknown as Bridge).cmuxAcpmuxBridge?.receive(structuredClone(snapshot));

const openSessionInfo: Play = async (ctx) => {
  const { setHeaderState } = await import("./header/headerState");
  const { setSessionInfoOpen } = await import("./session-info/sessionInfoState");
  setHeaderState({ inspector: true });
  setSessionInfoOpen(true);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info[data-presence='shown']"));
};

const toSecond: Play = async (ctx) => {
  deliver(ctx, secondChat());
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-thread-title")?.textContent?.startsWith("Profile"));
};

const backMidway: Play = async (ctx) => {
  // From the second chat (step 1) back to the first, then to the second again while the first is
  // still moving in: each part of the new switch starts from where it is drawn.
  deliver(ctx, first);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-thread-title")?.textContent?.startsWith("Why"));
  await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
  deliver(ctx, secondChat());
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-thread-title")?.textContent?.startsWith("Profile"));
};

export default agentPaneEntry({
  id: "agent-pane.chat-switch",
  title: "Chat switch motion",
  area: "Agent pane",
  experimental: true,
  height: 560,
  covers: ["agent-session/acpmux/chatSwitch.ts#playChatSwitch"],
  keywords: ["switch", "motion", "choreography", "transition", "spring", "session info"],
  variants: {
    "first-chat": {
      note: "The first chat with Session Info open: the state each switch starts from.",
      snapshot: first,
      play: openSessionInfo,
    },
    "second-chat": {
      note: "After the switch: the second chat, its title and Session Info.",
      snapshot: secondChat(),
      play: openSessionInfo,
    },
  },
  experiment: {
    definition: chatSwitchMotion,
    setup: openSessionInfo,
    script: [
      { name: "Open the second chat", run: toSecond },
      { name: "Back, then again mid-switch", run: backMidway },
    ],
  },
});
