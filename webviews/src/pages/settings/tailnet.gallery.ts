// l10n-allow-file: gallery fixtures (sample tailnet names and addresses), not shipped UI.
// Settings > Server > This Mac on Your Tailnet (TailnetCard): this Mac's own tailnet node, signed in
// and out through acpmux, under the Server card. The layouts it was picked from are settings.tailnet-layouts.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { TailnetState } from "./ops";

const shown: PageFixtureStep = { selector: '[data-card="tailnet"]', action: "wait" };
const variant = (tailnet: TailnetState, note: string, steps: PageFixtureStep[] = [shown]): SettingsPageVariant => ({
  section: "server",
  tailnet,
  steps,
  note,
});
const signIn = "https://login.tailscale.com/a/1a2b3c4d5e";

export default settingsPageEntry({
  id: "pages.settings-tailnet",
  title: "Settings This Mac on Your Tailnet",
  area: "Settings",
  height: 560,
  covers: ["pages/settings/components/TailnetCard.tsx#TailnetCard"],
  anchors: [{ selector: '[data-card="tailnet"]' }],
  variants: {
    "signed-out": variant({ state: "stopped" }, "Not signed in: what signing in does, and Sign In…."),
    "after-sign-in": variant(
      { state: "stopped" },
      "Sign In… pressed: the node asks for a login, and its sign-in page is a link the person opens.",
      [shown, { selector: '[data-tailnet-action="start"]', action: "click" }],
    ),
    "needs-login": variant(
      { state: "needs_login", browse_to_url: signIn },
      "Waiting on the browser: Open Sign-In Page and Cancel.",
    ),
    approval: variant(
      { state: "needs_machine_auth" },
      "Signed in, waiting for the tailnet's admin to approve this Mac.",
    ),
    "signed-in": variant(
      { state: "running", dns_name: "studio-mac.tail1234.ts.net", ips: ["100.101.102.103", "fd7a:115c:a1e0::1"] },
      "Signed in: this Mac's name and address on the tailnet, and Sign Out.",
    ),
    error: variant(
      { state: "error", error: "tailnet start was superseded" },
      "A failed start: acpmux's own text, and Try Again.",
    ),
  },
});
