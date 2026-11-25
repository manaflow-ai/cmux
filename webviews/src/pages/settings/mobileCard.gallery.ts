// l10n-allow-file: gallery fixtures, not shipped UI.
// Settings > Mobile (MobileCard): the iPhone host's card under the Allow iPhone Connections switch,
// from the host lists' `iphone`. How to Connect says where the iPhone app comes from (TestFlight),
// so a person with no cmux on their phone yet learns it here.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { IPhoneHostState } from "./ops";

const base: IPhoneHostState = {
  title: "Connection",
  allowed: true,
  status_title: "Status",
  status: "Online",
  sign_in: null,
  phase: "online",
  account_title: "Account",
  account: "Registered as me@example.com",
  space_title: "Space",
  space: "Personal",
  how_title: "How to Connect",
  how: "Install cmux on your iPhone and sign in with the same account as this Mac. This Mac then appears under Workspaces. No cmux on your iPhone yet? It’s in beta: get it through TestFlight.",
  phones_title: "Phones",
  phones_empty: "No phone has connected with this account yet.",
  phones: [],
  phones_error: null,
  remove_title: "Remove",
  remove_help:
    "Removes this phone from your account's devices and ends its connection. A phone still signed in adds itself again when it reconnects.",
  allow_again_title: "Allow Again",
  pending_title: "Connection Requests",
  pending: [],
  pair_allow_title: "Allow",
  pair_deny_title: "Don't Allow",
  blocked: null,
  blocked_help: "",
};
const shown: PageFixtureStep = { selector: '[data-card="mobile"]', action: "wait" };
const variant = (iphone: IPhoneHostState, note: string): SettingsPageVariant => ({
  section: "mobile",
  host: { iphone },
  steps: [shown],
  note,
});

export default settingsPageEntry({
  id: "pages.settings-mobile",
  title: "Settings Mobile",
  area: "Settings",
  height: 960,
  covers: ["pages/settings/components/MobileCard.tsx"],
  anchors: [{ selector: '[data-card="mobile"]' }],
  variants: {
    "signed-out": variant(
      {
        ...base,
        status: "Sign in to cmux to allow iPhone connections.",
        sign_in: "Sign In",
        phase: "off",
        account: null,
        space: null,
      },
      "A new person, not signed in: Sign In beside the status, and How to Connect says where the iPhone app comes from.",
    ),
    "no-phone-yet": variant(
      base,
      "Signed in, no phone has connected yet: How to Connect names TestFlight for a person with no cmux on their iPhone.",
    ),
    "phone-connected": variant(
      {
        ...base,
        status: "Online · Phones connected: 1",
        phones: [
          {
            id: "p1",
            title: "Aziz's iPhone",
            subtitle: "Video over WebRTC (direct)",
            connected: true,
            removable: true,
            transport: "webrtc",
            path: "direct",
          },
        ],
      },
      "A phone already connected: the same How to Connect line stays for a second phone.",
    ),
  },
});
