// l10n-allow-file: gallery fixtures, not shipped UI.
// The guest page in a shared chat (design/chat-multiplayer.md section 3; Leo 2026-10-28: the guest
// watches the agent work live, "including command output and the agent's reasoning"): the owner's
// own transcript, read only, fed by a fake room. `asking` is an ask only the owner answers;
// `view-only` an account invitee with the view role.
import { componentEntry } from "../../gallery/format";
import {
  askingRecords,
  fakeRoom,
  guestMessageRecords,
  joinFrames,
  memoryStorage,
  workingRecords,
  queuedRecords,
} from "./fixtures/liveChat";
import type { GuestPageProps } from "./GuestPage";

const live = (frames: object[]): GuestPageProps => ({
  shareId: "c2hhcmUtZ2FsbGVyeQ",
  guestId: "g1",
  role: "talk",
  storage: memoryStorage(),
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
  covers: [
    "agent-session/guest/GuestPage.tsx",
    "agent-session/acpmux/rows/ReadOnlyAgentPairRow.tsx",
    "agent-session/acpmux/rows/ReadOnlyNextStepRow.tsx",
    "agent-session/acpmux/rows/ReadOnlyPermissionRow.tsx",
    "agent-session/acpmux/rows/ReadOnlyQueuedMessageRow.tsx",
  ],
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
        // A folded thought reads its own words by the brain glyph (Codex parity), not "Thought".
        await ctx.waitFor(() => ctx.document.querySelector('button.cv-thought[aria-expanded="false"]'));
        await ctx.click({ selector: 'button.cv-thought[aria-expanded="false"]' });
        // The failed run, by its tool id: a failed call keeps its command line (commandActions.ts),
        // so a label selector would break whenever the wording changes.
        await ctx.waitFor(() => ctx.document.querySelector('button[data-tool-id="run-1"]'));
        await ctx.click({ selector: 'button[data-tool-id="run-1"]' });
        await ctx.waitFor(() => ctx.document.body.textContent?.includes("Test timed out after 5000ms"));
      },
    },
    driving: {
      props: { ...live(joinFrames(workingRecords())), role: "drive", invite: true },
      note: "A named Drive invite can send a message or stop the current turn.",
    },
    "guest-messages": {
      props: live(joinFrames(guestMessageRecords(), "Uploader retries")),
      note: 'Two signed-in guests\' approved messages as prompts under their 20px picture (else initials) and name (guest); Leo, 2026-11-07: "as if the user sent it, but, like, with their profile avatar picture instead".',
    },
    "owner-queued": {
      props: live(joinFrames(queuedRecords(["Then run the whole suite 20 times to be sure."]))),
      note: "The owner sent a follow-up while the agent works: the guest sees it at once above the composer, marked Queued, before it becomes a row.",
    },
    "owner-queued-several": {
      props: live(
        joinFrames(
          queuedRecords([
            "Then run the whole suite 20 times to be sure.",
            "Also check the download retry: it uses the same backoff helper and probably has the same real-clock wait.",
            "Open a pull request when both pass.",
          ]),
        ),
      ),
      note: "Three follow-ups waiting, in the order they will run; the list scrolls past its height and the composer stays put.",
    },
    "owner-queued-view-only": {
      props: {
        ...live(joinFrames(queuedRecords(["Then run the whole suite 20 times to be sure."]))),
        role: "view",
      },
      note: "A guest who may only watch sees the owner's waiting follow-up too.",
    },
    asking: {
      props: live(joinFrames(askingRecords())),
      note: "The agent asks to run a command; only the owner answers, the guest sees who it waits on.",
    },
    connecting: {
      props: live([]),
      note: "Before the room's snapshot: the final layout already, the composer at the bottom and the transcript's area held empty.",
    },
    "connecting-view-only": {
      props: { ...live([]), role: "view" },
      note: "A link guest's first frame before the snapshot: the view-only line already at the bottom.",
    },
    "load-failed": {
      props: {
        ...live(joinFrames(workingRecords())),
        role: "view",
        loadTranscript: () => Promise.reject(new Error("offline")),
        reloadPage: () => undefined,
      },
      note: "The transcript's chunk could not load (a dropped connection): the page keeps trying on its own (and reloads once, since a browser may keep the failed fetch), with no Retry; past 25 s one quiet line, Still loading the chat… (Leo, 2026-11-22).",
    },
    "view-only": {
      props: { ...live(joinFrames(workingRecords())), role: "view" },
      note: "An invitee who may only watch: no composer, the page says so.",
    },
  },
});
