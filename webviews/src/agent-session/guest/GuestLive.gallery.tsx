// l10n-allow-file: gallery fixtures, not shipped UI.
// The guest page in a shared chat (design/chat-multiplayer.md section 3; Leo 2026-10-28: the guest
// watches the agent work live, "including command output and the agent's reasoning"): the owner's
// own transcript, read only, fed by a fake room. `asking` is an ask only the owner answers.
import { componentEntry } from "../../gallery/format";
import { askingRecords, fakeRoom, joinFrames, workingRecords } from "./fixtures/liveChat";
import type { GuestPageProps } from "./GuestPage";

const live = (frames: object[]): GuestPageProps => ({
  shareId: "c2hhcmUtZ2FsbGVyeQ",
  guestId: "g1",
  redeem: () => new Promise(() => undefined),
  attempt: () => "0".repeat(32),
  socketUrl: "wss://room.invalid/v1/chat-shares/c2hhcmUtZ2FsbGVyeQ/guest",
  openSocket: fakeRoom(frames),
});

export default componentEntry<GuestPageProps>({
  id: "guest-page.live",
  title: "Guest page: shared chat",
  area: "Agent pane",
  keywords: ["multiplayer", "share", "guest", "read only", "transcript"],
  covers: ["agent-session/guest/GuestPage.tsx"],
  height: 720,
  // A phone browser at narrow.
  widths: { narrow: 390 },
  pane: true,
  load: () => import("./GuestPage").then((module) => module.GuestPage),
  variants: {
    working: {
      props: live(joinFrames(workingRecords())),
      note: "The agent mid-turn: its reasoning and a failed test run's output, opened; a second run going.",
      // Opened as the owner would: "including command output and the agent's reasoning".
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.body.textContent?.includes("Thought"));
        await ctx.click({ text: "Thought" });
        await ctx.click({ text: /^Ran bun test/ });
        await ctx.waitFor(() => ctx.document.body.textContent?.includes("Test timed out after 5000ms"));
      },
    },
    asking: {
      props: live(joinFrames(askingRecords())),
      note: "The agent asks to run a command; only the owner answers, the guest sees who it waits on.",
    },
    connecting: { props: live([]), note: "Before the room's snapshot." },
  },
});
