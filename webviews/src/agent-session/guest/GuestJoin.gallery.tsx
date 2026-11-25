// l10n-allow-file: gallery fixtures, not shipped UI.
// The guest page before Join (design/chat-multiplayer.md section 3; Leo 2026-10-28, on T3 Code's
// "Share with guest": "we want to be having, be able to do this kind of flow for CMux
// multiplayer"): nothing about the chat, one field, Join. `offline` is a redeem the owner's
// computer could not answer; `bad-link` a link that lost its secret. The `invite-*` variants are an
// account invite (/i/<id>): the room signed the visitor in, so there is no name field, only Join.
// The `signed-in*` variants are a link opened by someone signed in to cmux (the room's whoami):
// "Join as <name>" with their picture, and Edit name (Leo, 2026-11-07: "they can just use their
// cmux account ... although they could customize their name potentially if they wanted to").
// The `sign-in-*` variants are a link opened signed out on a room that answers whoami: the name
// prompt, and a Sign in that comes back to the same link (Leo: "the sharing, you know, we really
// need to hill climb that like sort of Google Docs-esque type sharing"); `-returned` is that tab
// back from the sign-in, joining as the account.
import { componentEntry } from "../../gallery/format";
import { memoryStorage } from "./fixtures/liveChat";
import type { GuestPageProps } from "./GuestPage";
import { AVATAR } from "../acpmux/multiplayer/people.fixtures";

const base: GuestPageProps = {
  shareId: "c2hhcmUtZ2FsbGVyeQ",
  secret: "c2VjcmV0LWdhbGxlcnk",
  storage: memoryStorage(),
  redeem: () => new Promise(() => undefined),
  attempt: () => "0".repeat(32),
  socketUrl: "",
};

const invite: GuestPageProps = { ...base, secret: undefined, invite: true };

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
    "signed-in": {
      props: { ...base, whoami: () => Promise.resolve({ signedIn: true, name: "Priya Raman", avatarUrl: AVATAR }) },
      note: "Signed in to cmux: Join as the account, with its picture; Edit name opens the field.",
      play: async (ctx) => await ctx.waitFor(() => ctx.document.querySelector(".guest-join__as")),
    },
    "signed-in-initials": {
      props: { ...base, whoami: () => Promise.resolve({ signedIn: true, name: "Tomás Ortega" }) },
      note: "Signed in, and the account has no picture: its initials.",
      play: async (ctx) => await ctx.waitFor(() => ctx.document.querySelector(".guest-join__as")),
    },
    "signed-in-edit-name": {
      props: {
        ...base,
        editName: true,
        whoami: () => Promise.resolve({ signedIn: true, name: "Priya Raman", avatarUrl: AVATAR }),
      },
      note: "Edit name opened: the field holds the account's name; Join joins with what it says.",
      play: async (ctx) => await ctx.waitFor(() => ctx.document.querySelector("input")),
    },
    "sign-in-offer": {
      props: { ...base, whoami: () => Promise.resolve({ signedIn: false }) },
      note: "Signed out on a link: the name prompt as before, and Sign in to join as a cmux account.",
      play: async (ctx) => await ctx.waitFor(() => ctx.document.querySelector("[data-testid='guest-join-sign-in']")),
    },
    "sign-in-returned": {
      props: { ...base, whoami: () => Promise.resolve({ signedIn: true, name: "Priya Raman", avatarUrl: AVATAR }) },
      note: "Back from Sign in on the same link: Join as the account; the secret came back from this tab's storage.",
      play: async (ctx) => await ctx.waitFor(() => ctx.document.querySelector(".guest-join__as")),
    },
    "sign-in-returned-long-name": {
      props: {
        ...base,
        whoami: () =>
          Promise.resolve({ signedIn: true, name: "Maximiliana Alexandrova-Fitzgerald de la Cruz Montgomery" }),
      },
      note: "Back from Sign in with a long account name (see it at narrow): the name wraps or cuts, the button holds.",
      play: async (ctx) => await ctx.waitFor(() => ctx.document.querySelector(".guest-join__as")),
    },
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
