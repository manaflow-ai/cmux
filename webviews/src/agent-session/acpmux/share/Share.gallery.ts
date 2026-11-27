// l10n-allow-file: gallery fixtures (made-up people), not shipped UI.
// Sharing an agent chat (Leo, 2026-11-07: "like the Figma and the Google Docs, like the
// collaborators thing"), opened from the chat's ••• menu, not a header button (Leo: "would that
// defeat the minimalism? ... you'd want to put it in the dot dot dot area"). The header shows only
// who else is here, and only while someone is. Variants: an unshared chat (nothing new), a shared
// one with faces, the dialog empty and shared, and the copied-link toast.
import { componentEntry } from "../../../gallery/format";
import { ANA, JORDAN, MEI, SAM } from "../multiplayer/people.fixtures";
import type { ShareDemoProps } from "./ShareDemo";
import type { ChatShare, ShareAccessRequest } from "./shareState";

const link: ChatShare = {
  shareId: "link-1",
  state: "active",
  url: null,
  inviteUrl: "https://share.example.com/i/link-1",
  role: "view",
  createdAt: 1,
  expiresAt: 0,
  usesLeft: 999,
  guests: [{ guestId: "g1", name: "Riley", account: null, role: "view", joined: true }],
  invitees: [],
};
const people: ChatShare = {
  shareId: "invite-1",
  state: "active",
  url: null,
  inviteUrl: "https://share.example.com/i/invite-1",
  role: null,
  createdAt: 2,
  expiresAt: 0,
  usesLeft: 0,
  guests: [{ guestId: "g2", name: "Ana Ruiz", account: "ana@example.com", role: "talk", joined: true }],
  invitees: [
    { account: "ana@example.com", role: "talk", state: "invited", joined: true },
    { account: "@sam", role: "view", state: "invited", joined: false },
  ],
};
const viewing = [ANA, SAM, MEI, JORDAN];
// Stress: invites nobody opened yet beside people in the chat now, a long address, and a list
// past the four rows the band shows before it scrolls.
const pending: ChatShare = {
  ...people,
  shareId: "invite-2",
  guests: [{ guestId: "g3", name: "Ana Ruiz", account: "ana@example.com", role: "talk", joined: true }],
  invitees: [
    { account: "ana@example.com", role: "talk", state: "invited", joined: true },
    { account: "@sam", role: "view", state: "invited", joined: false },
    {
      account: "alexandria.montgomery-fitzgerald@engineering.verylongcompanyname.example.com",
      role: "view",
      state: "invited",
      joined: false,
    },
  ],
};
const crowd: ChatShare = {
  ...people,
  shareId: "invite-3",
  guests: [
    { guestId: "c1", name: "Ana", account: "ana@example.com", role: "talk", joined: true },
    { guestId: "c2", name: "Mei", account: "mei@example.com", role: "view", joined: false },
  ],
  invitees: [
    "ana@example.com",
    "mei@example.com",
    "@sam",
    "@jordan",
    "riley@example.com",
    "@priya",
    "noah.williams@example.com",
    "@kenji",
    "lucia@example.com",
    "@omar",
    "@zoe",
    "ivan@example.com",
  ].map((account, index) => ({
    account,
    role: index % 3 === 0 ? "talk" : "view",
    state: "invited",
    joined: index === 0,
  })),
};

// Access requests (RFD 0077 D5): signed-in accounts that opened the link without access asked in.
const ask = (account: string, name: string, requestedAt: number): ShareAccessRequest => ({
  account,
  name,
  avatarUrl: null,
  requestedAt,
});
const oneAsk: ChatShare = { ...people, shareId: "ask-1", requests: [ask("mei@example.com", "Mei Chen", 10)] };
const threeAsks: ChatShare = {
  ...people,
  shareId: "ask-3",
  requests: [
    ask("mei@example.com", "Mei Chen", 10),
    ask("@jordan", "Jordan Lee", 11),
    ask("riley@example.com", "Riley Park", 12),
  ],
};
const longAsk: ChatShare = {
  ...people,
  shareId: "ask-long",
  requests: [
    ask(
      "alexandria.montgomery-fitzgerald@engineering.verylongcompanyname.example.com",
      "Alexandria Montgomery-Fitzgerald of the Platform Reliability Group",
      10,
    ),
    ask("@sam-the-very-long-handle-name", "", 11),
  ],
};

export default componentEntry<ShareDemoProps>({
  id: "agent-pane.share",
  title: "Agent pane: share a chat",
  area: "Agent pane",
  keywords: ["share", "sharing", "collaborators", "avatars", "invite", "link", "Google Docs", "Figma"],
  covers: [
    "agent-session/acpmux/share/ShareControl.tsx",
    "agent-session/acpmux/share/ShareDialog.tsx",
    "agent-session/acpmux/share/ShareDemo.tsx",
  ],
  load: () => import("./ShareDemo").then((module) => module.ShareDemo),
  styles: () => import("./Share.gallery.css"),
  height: 560,
  widths: { narrow: 280, normal: 480, wide: 800 },
  variants: {
    unshared: {
      note: "An unshared chat: nothing new in the header (no Share button, no faces).",
      props: { viewing: [], shares: [] },
    },
    shared: {
      note: "A shared chat with people in it: their faces, overlapping with +N, and nothing else new.",
      props: { viewing, shares: [people, link] },
    },
    "dialog-restricted": {
      note: "Share… from the ••• menu on a chat shared with nobody yet: Restricted, only the owner.",
      props: { viewing: [], shares: [], open: true },
    },
    "dialog-shared": {
      note: "Two people invited (one in the chat now) and Anyone with the link, whose row says Can send: signed-in people can send messages, others can view (cmux#38102). Shipped: the sheet role's glass, veil and 14 px corners; every control a 28 px shared button or field; Done the one solid button.",
      props: { viewing, shares: [people, link], open: true },
    },
    "rows-restricted-back": {
      note: "Shipped: General access and each person are one button the size of their row, edged at rest like a sign-in choice, with the hover and press fills on the whole block; pressing General access offers Restricted, which turns the link back off.",
      props: { viewing, shares: [people, link], open: true },
    },
    "look-row-hover": {
      note: "Compared, not shipped: no edge at rest, the fill only on hover. The rows read as plain text until the pointer finds them, the dead-chip problem again.",
      props: { viewing, shares: [people, link], open: true, look: "row-hover" },
    },
    "look-row-filled": {
      note: "Compared, not shipped: the rows filled at rest. Every row reads as pressed, so the hover says nothing.",
      props: { viewing, shares: [people, link], open: true, look: "row-filled" },
    },
    "look-row-bleed": {
      note: "Compared, not shipped: square rows divided by hairlines, a list rather than buttons. Nothing says a row presses.",
      props: { viewing, shares: [people, link], open: true, look: "row-bleed" },
    },
    "look-two-primaries": {
      note: "Compared, not shipped: Invite solid as well as Done. Two accent buttons compete for the one primary action.",
      props: { viewing, shares: [people, link], open: true, look: "two-primaries" },
    },
    "look-popover": {
      note: "Compared, not shipped: the popover level's glass (the theme surface at 70%) and the 12 px card radius instead of the sheet role.",
      props: { viewing, shares: [people, link], open: true, look: "popover" },
    },
    "look-outline": {
      note: "Compared, not shipped: hairline-outlined field, selects and buttons with no fill at rest.",
      props: { viewing, shares: [people, link], open: true, look: "outline" },
    },
    "dialog-pending": {
      note: 'Invited, not opened yet: each invite nobody has opened says "Hasn\'t opened it yet" under the address; someone in the chat now says that instead. A long address ellipsizes and never pushes the role or Remove out.',
      props: { viewing, shares: [pending], open: true },
    },
    "dialog-many": {
      note: "Twelve people: the band keeps four rows and scrolls, so the dialog is one size however many are invited.",
      props: { viewing, shares: [crowd, link], open: true },
    },
    "dialog-long-title": {
      note: "A long chat title ellipsizes on one line.",
      props: {
        viewing: [],
        shares: [pending],
        open: true,
        chat: "Investigate why the nightly uploader retries forever when the bucket region changes mid-run",
      },
    },
    "dialog-offline": {
      note: "The share server does not answer: the error line says so in plain words, where it always has room, so nothing moves.",
      props: { viewing: [], shares: [], open: true, fail: "share.room_unreachable" },
    },
    "requests-one": {
      note: "One account asked for access (RFD 0077 D5): its row sits above People with access, with a role picker that starts at Can view, Approve and Decline. The people band gives up the row's room, so the dialog keeps its height. Picking Can send puts what it means on the status line; Decline is silent.",
      props: { viewing, shares: [oneAsk, link], open: true },
    },
    "requests-three": {
      note: "Three requests: the band holds two rows and scrolls to the third, and the heading counts them, so the dialog never grows.",
      props: { viewing, shares: [threeAsks, link], open: true },
    },
    "requests-narrow-long": {
      note: "At 280 px (pick the narrow width) with a long name and address, and a handle with no name: each request takes two lines, the name and address ellipsize on the first, the role, Approve and an x on the second.",
      props: { viewing, shares: [longAsk], open: true },
    },
    "requests-none": {
      note: "No requests: no band and no heading; the dialog is as it was.",
      props: { viewing, shares: [people], open: true },
    },
    "dialog-still-reading": {
      note: 'The daemon does not answer the dialog\'s read: no "Try again", it reads again on its own on the shared backoff (autoRetry.ts) and, once that has lasted (at once here), says only "Still reading who has access…" as the quiet status line. A failed share change (an invite, a role, a link) still says "That didn\'t finish. Try again.": that is a write the person chooses.',
      props: { viewing: [], shares: [people], open: true, unread: true },
    },
    toast: {
      note: "After Copy link with Anyone with the link: the toast and Manage links.",
      props: { viewing, shares: [link], toast: "public" },
    },
  },
});
