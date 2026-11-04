// l10n-allow-file: gallery fixtures, not shipped UI.
// The guest page before Join (design/chat-multiplayer.md section 3; Leo 2026-10-28, on T3 Code's
// "Share with guest": "we want to be having, be able to do this kind of flow for CMux
// multiplayer"): nothing about the chat, one field, Join. `offline` is a redeem the owner's
// computer could not answer; `bad-link` a link that lost its secret. The `invite-*` variants are an
// account invite (/i/<id>): the room signed the visitor in, so there is no name field, only Join.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { fakeRoom, joinFrames, memoryStorage, workingRecords } from "./fixtures/liveChat";
import type { GuestPageProps } from "./GuestPage";

const base: GuestPageProps = {
  shareId: "c2hhcmUtZ2FsbGVyeQ",
  secret: "c2VjcmV0LWdhbGxlcnk",
  storage: memoryStorage(),
  redeem: () => new Promise(() => undefined),
  attempt: () => "0".repeat(32),
  socketUrl: "",
};

const invite: GuestPageProps = { ...base, secret: undefined, invite: true };

/**
 * A tab that joined by the link (one message still waiting for the owner as that guest), then
 * opened the invite and pressed Join: it is the invitee now, with its own empty outbox (cmux#34013).
 */
const afterLink = (role: "view" | "talk"): GuestPageProps => {
  const storage = memoryStorage(
    base.shareId,
    [{ clientId: "c-link", text: "Sent as the link guest", at: 0, state: "held" }],
    "g-link",
  );
  storage.setItem(`cmux.guest.${base.shareId}.joined`, "g-link");
  return {
    ...invite,
    storage,
    accept: () => Promise.resolve({ ok: true, guestId: "g1", role }),
    socketUrl: "wss://room.invalid/v1/chat-shares/c2hhcmUtZ2FsbGVyeQ/guest",
    openSocket: fakeRoom(joinFrames(workingRecords())),
  };
};
const acceptJoin: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Join" });
  await ctx.waitFor(() => ctx.document.querySelector(".guest-live"));
};

export default componentEntry<GuestPageProps>({
  id: "guest-page.join",
  title: "Guest page: join",
  area: "Agent pane",
  keywords: ["multiplayer", "share", "guest", "invite link", "invite", "sign in"],
  covers: ["agent-session/guest/GuestPage.tsx"],
  height: 520,
  // A phone browser at narrow.
  widths: { narrow: 390 },
  pane: true,
  load: () => import("./GuestPage").then((module) => module.GuestPage),
  variants: {
    empty: { props: base, note: "The link opened: Join waits for a name." },
    offline: {
      props: { ...base, redeem: () => Promise.resolve({ ok: false, error: "share.host_offline" }) },
      note: "Join tried while the owner's computer was offline; Join again works.",
      play: async (ctx) => {
        await ctx.type("Ana", { selector: "input" });
        await ctx.click({ role: "button", name: "Join" });
        await ctx.waitFor(() => ctx.document.querySelector("[role='alert']"));
      },
    },
    "bad-link": { props: { ...base, secret: undefined }, note: "The link lost its secret part when copied." },
    invite: {
      props: { ...invite, accept: () => new Promise(() => undefined) },
      note: "An account invite, signed in: no name field, Join joins as the cmux account.",
    },
    "invite-not-invited": {
      props: { ...invite, accept: () => Promise.resolve({ ok: false, error: "share.not_invited" }) },
      note: "Signed in with an account the owner did not invite.",
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Join" });
        await ctx.waitFor(() => ctx.document.querySelector("[role='alert']"));
      },
    },
    "invite-after-link-talk": {
      props: afterLink("talk"),
      note: "Joined by the link first, then accepted the invite: a talk invitee, the link guest's waiting message not carried over.",
      play: acceptJoin,
    },
    "invite-after-link-view": {
      props: afterLink("view"),
      note: "Joined by the link first, then accepted a view invite: watch only, no composer.",
      play: acceptJoin,
    },
    "invite-signed-out": {
      props: { ...invite, accept: () => Promise.resolve({ ok: false, error: "share.unauthorized" }) },
      note: "The sign-in lapsed before Join: a link signs in again.",
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Join" });
        await ctx.waitFor(() => ctx.document.querySelector("[role='alert'] a"));
      },
    },
  },
});
