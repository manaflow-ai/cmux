// l10n-allow-file: gallery fixtures, not shipped UI.
// Public-safe host projections for the real Settings page; these do not start a tailnet node.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";
import type { TailnetState } from "./ops";

const signedOut: TailnetState = {
  title: "This Mac on Your Tailnet",
  phase: "signed_out",
  status_title: "Tailscale",
  status: "Sign in to reach this Mac from your other devices.",
  busy: false,
  error: null,
  limited: true,
  limit_editable: false,
  limit_title: "Limit access to your Tailscale account",
  limit_help: "Only your Tailscale account can connect for now.",
  sign_in_title: "Sign In…",
  reopen_title: "Reopen",
  cancel_title: "Cancel",
  sign_out_title: "Sign Out",
  address_title: "Remote Address",
  copy_title: "Copy",
  pair_title: "Pair…",
  done_title: "Done",
};

const variant = (tailnet: TailnetState, note: string): SettingsPageVariant => ({
  section: "accounts",
  host: { tailnet },
  steps: [{ selector: '[data-card="tailnet"]', action: "wait" }],
  note,
});

export default settingsPageEntry({
  id: "pages.settings-tailnet",
  title: "Settings Tailnet",
  area: "Settings",
  height: 820,
  covers: ["pages/settings/components/TailnetCard.tsx"],
  anchors: [{ selector: '[data-card="tailnet"]' }],
  variants: {
    unavailable: variant(
      { ...signedOut, phase: "unavailable", status: "This daemon does not include a tailnet node." },
      "Labs is enabled but the daemon has no own-node backend: no Sign In button is offered.",
    ),
    "signed-out": variant(signedOut, "Sign In starts the browser flow; the owner-only switch stays disabled."),
    waiting: variant(
      { ...signedOut, phase: "waiting", status: "Finish signing in in your browser." },
      "Cancel and Reopen while sign-in waits; no authentication URL is sent to the page.",
    ),
    "signed-in": variant(
      {
        ...signedOut,
        phase: "signed_in",
        status: "Signed in as sample@example.com",
        address: "https://sample-mac.example.ts.net",
      },
      "The address has Copy and Pair actions, with Sign Out above; this fixture is not backend evidence.",
    ),
  },
});
