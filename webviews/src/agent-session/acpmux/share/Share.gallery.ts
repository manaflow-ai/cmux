// l10n-allow-file: gallery fixtures (made-up people), not shipped UI.
// Sharing an agent chat (Leo, 2026-11-07: "like the Figma and the Google Docs, like the
// collaborators thing"), opened from the chat's ••• menu, not a header button (Leo: "would that
// defeat the minimalism? ... you'd want to put it in the dot dot dot area"). The header shows only
// who else is here, and only while someone is. Variants: an unshared chat (nothing new), a shared
// one with faces, the dialog empty and shared, and the copied-link toast.
import { componentEntry } from "../../../gallery/format";
import { ANA, JORDAN, MEI, SAM } from "../multiplayer/people.fixtures";
import type { ShareDemoProps } from "./ShareDemo";
import type { ChatShare } from "./shareState";

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
      note: "Two people invited (one in the chat now) and Anyone with the link as a viewer. Shipped: the sheet role's glass, veil and 14 px corners; every control a 28 px shared button or field; Done the one solid button.",
      props: { viewing, shares: [people, link], open: true },
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
    toast: {
      note: "After Copy link with Anyone with the link: the toast and Manage links.",
      props: { viewing, shares: [link], toast: "public" },
    },
  },
});
