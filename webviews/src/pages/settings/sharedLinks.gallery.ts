// l10n-allow-file: gallery fixtures (sample chats and guests), not shipped UI.
// Settings > Privacy and Security > Shared Links (SharedLinksCard): every live chat share this Mac
// holds, with Revoke and Revoke All. The layouts it was picked from are settings.shared-links-layouts.
import { GALLERY_NOW } from "../../gallery/clock";
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockShares } from "./mockProvider";
import type { SharesState } from "./ops";

const hour = 3_600_000;
const shown: PageFixtureStep = { selector: '[data-card="sharedLinks"]', action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "privacy",
  focus: "card.sharedLinks",
  steps: [shown],
  ...patch,
});
const base = mockShares(GALLERY_NOW);
const many: SharesState = {
  available: true,
  titles: {
    ...base.titles,
    "40": "Migrate the billing webhooks to the new queue without dropping retries or duplicate deliveries",
    "41": "Review the release notes",
  },
  shares: [
    ...(base.shares ?? []),
    {
      share_id: "sh_link_0004",
      state: "active",
      session: "s-billing",
      surface: 40,
      created_at: GALLERY_NOW - 5 * 60_000,
      expires_at: GALLERY_NOW + 24 * hour,
      uses_left: 1,
      invite_url: null,
      guests: [
        { guest_id: "g2", name: "Riley", joined_at: GALLERY_NOW - 60_000, state: "active" },
        {
          guest_id: "g3",
          name: "Avery",
          joined_at: GALLERY_NOW - 30_000,
          state: "active",
          account: "@avery",
          role: "talk",
        },
      ],
      invitees: [],
    },
    {
      share_id: "sh_link_0005",
      state: "provisioning",
      session: "s-notes",
      surface: 41,
      created_at: GALLERY_NOW - 50 * hour,
      expires_at: GALLERY_NOW + 3 * hour,
      uses_left: 1,
      invite_url: null,
      guests: [],
      invitees: [],
    },
    {
      share_id: "sh_link_0006",
      state: "active",
      session: "s-gone",
      surface: 99,
      created_at: GALLERY_NOW - 80 * hour,
      expires_at: GALLERY_NOW + 88 * hour,
      uses_left: 1,
      invite_url: null,
      guests: [],
      invitees: [],
    },
  ],
};

export default settingsPageEntry({
  id: "pages.settings-shared-links",
  title: "Settings Shared Links",
  area: "Settings",
  height: 560,
  covers: ["pages/settings/components/SharedLinksCard.tsx#SharedLinksCard"],
  anchors: [{ selector: '[data-card="sharedLinks"]' }],
  variants: {
    shipped: variant({
      note: "Two live shares: a guest link with a guest in it and an invite share; an ended link is left out.",
    }),
    many: variant({
      sharedLinks: many,
      note: "Five shares: a long chat name truncates in its row, a chat with no open tab reads Untitled chat.",
    }),
    "revoke-all": variant({
      steps: [shown, { selector: '[data-shared-links-action="revokeAll"]', action: "click" }],
      note: "Revoke All asks first, inline: the links stop working and every guest leaves at once.",
    }),
    empty: variant({
      sharedLinks: { available: true, shares: [], titles: {} },
      note: "Nothing shared: one short line.",
    }),
    unavailable: variant({
      sharedLinks: { available: false },
      note: "This Mac's daemon is not connected: one short line instead of the list.",
    }),
  },
});
