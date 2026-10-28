// l10n-allow-file: gallery fixtures, not shipped UI.
// The guest's own messages (design/chat-multiplayer.md section 3; Leo 2026-10-28: each message the
// guest sends waits for the owner): a held one shows the guest's chip and "Waiting for <owner>";
// decided ones fold to one quiet line each, "Sent", "Declined" or "Not sent".
import { componentEntry } from "../../gallery/format";
import { fakeRoom, joinFrames, memoryStorage, workingRecords } from "./fixtures/liveChat";
import type { GuestPrompt } from "./guestPrompts";
import type { GuestPageProps } from "./GuestPage";

const SHARE = "c2hhcmUtZ2FsbGVyeQ";
const AT = Date.UTC(2026, 9, 6, 9, 40, 0);
const prompt = (clientId: string, text: string, state: GuestPrompt["state"], reason?: string): GuestPrompt => ({
  clientId,
  text,
  at: AT,
  state,
  ...(reason ? { reason } : {}),
});

const page = (prompts: GuestPrompt[]): GuestPageProps => ({
  shareId: SHARE,
  guestId: "g1",
  name: "Ana",
  storage: memoryStorage(SHARE, prompts),
  redeem: () => new Promise(() => undefined),
  attempt: () => "0".repeat(32),
  socketUrl: "wss://room.invalid/v1/chat-shares/c2hhcmUtZ2FsbGVyeQ/guest",
  openSocket: fakeRoom(
    joinFrames(
      workingRecords(),
      undefined,
      prompts.map((each) => ({
        client_id: each.clientId,
        state: each.state,
        ...(each.reason ? { reason: each.reason } : {}),
      })),
    ),
  ),
});

export default componentEntry<GuestPageProps>({
  id: "guest-page.waiting",
  title: "Guest page: my messages",
  area: "Agent pane",
  keywords: ["multiplayer", "share", "guest", "held", "approve", "composer"],
  covers: ["agent-session/guest/GuestComposer.tsx", "agent-session/guest/GuestPage.tsx"],
  height: 760,
  // A phone browser at narrow.
  widths: { narrow: 390 },
  pane: true,
  load: () => import("./GuestPage").then((module) => module.GuestPage),
  variants: {
    held: {
      props: page([
        prompt("c1", "Can you run it on the CI image too?", "approved"),
        prompt("c2", "Could the test use a fake clock instead of real sleeps?", "held"),
      ]),
      note: "One message waits for the owner; the one before it was sent.",
    },
    decided: {
      props: page([
        prompt("c1", "Can you run it on the CI image too?", "approved"),
        prompt("c2", "Skip the test for now", "declined"),
        prompt("c3", "And bump the timeout to 30 s", "refused", "share.too_many_held"),
      ]),
      note: "Decided messages, one quiet line each: sent, declined, and refused with a reason.",
    },
  },
});
