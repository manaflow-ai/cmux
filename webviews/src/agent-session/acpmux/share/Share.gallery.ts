// l10n-allow-file: gallery fixtures (made-up people), not shipped UI.
// Sharing an agent chat (Leo, 2026-11-07: "like the Figma and the Google Docs, like the
// collaborators thing"): who is here and Share in the header's top right, the Share dialog, and
// the copied-link toast. Three looks for the button; the pick is `icon`, the toolbar's own 24px
// glyph beside the faces: it keeps the row's pitch and its no-resting-fill rule
// (design/chat-header.md), where a word or a filled button would be the only labeled tool there.
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
  height: 560,
  variants: {
    picked: {
      note: "The pick: the faces, then Share as the toolbar's 24px glyph (same pitch, no resting fill).",
      props: { look: "icon", viewing, shares: [] },
    },
    label: {
      note: "Glyph and word: clearer, but the only labeled tool in the row.",
      props: { look: "label", viewing, shares: [] },
    },
    filled: {
      note: "Google Docs' filled Share button: loudest; the accent fill fights the tool row's quiet glyphs.",
      props: { look: "filled", viewing, shares: [] },
    },
    "dialog-restricted": {
      note: "The dialog for a chat shared with nobody yet: Restricted, only the owner.",
      props: { look: "icon", viewing: [], shares: [], open: true },
    },
    "dialog-shared": {
      note: "Two people invited (one in the chat now) and Anyone with the link as a viewer.",
      props: { look: "icon", viewing, shares: [people, link], open: true },
    },
    toast: {
      note: "After Copy link with Anyone with the link: the toast and Manage links.",
      props: { look: "icon", viewing, shares: [link], toast: "public" },
    },
  },
});
