// l10n-allow-file: gallery fixtures (sample tailnet names and addresses), not shipped UI.
// Settings > Server > This Mac on Your Tailnet (TailnetCard): this Mac's own tailnet node, signed in
// and out through acpmux, under the Server card. The layouts it was picked from are settings.tailnet-layouts.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { HostLists, TailnetState } from "./ops";

const shown: PageFixtureStep = { selector: '[data-card="tailnet"]', action: "wait" };
const variant = (tailnet: TailnetState, note: string, steps: PageFixtureStep[] = [shown]): SettingsPageVariant => ({
  section: "server",
  tailnet,
  steps,
  note,
});
const cloudShown: PageFixtureStep = { selector: '[data-card="tailnet-cloud"]', action: "wait" };
const openSheet: PageFixtureStep[] = [cloudShown, { selector: "[data-tailnet-vm-join]", action: "click" }];
const fill = (key: string): PageFixtureStep[] => [
  { selector: "[data-tailnet-join-vm]", action: "input", value: "vm_studio" },
  { selector: "[data-tailnet-join-key]", action: "input", value: key },
];
const openConnect: PageFixtureStep[] = [cloudShown, { selector: "[data-tailnet-vm-connect]", action: "click" }];
const connectFill = (key: string): PageFixtureStep[] => [
  { selector: "[data-tailnet-connect-vm]", action: "input", value: "vm_studio" },
  { selector: "[data-tailnet-connect-key]", action: "input", value: key },
];
const signIn = "https://login.tailscale.com/a/1a2b3c4d5e";
const cloudHost: Partial<HostLists> = {
  machines: [{ id: "vm_studio", title: "Studio Cloud", subtitle: "Online", active: true }],
};

export default settingsPageEntry({
  id: "pages.settings-tailnet",
  title: "Settings This Mac on Your Tailnet",
  area: "Settings",
  height: 560,
  covers: [
    "pages/settings/components/TailnetCard.tsx#TailnetCard",
    "pages/settings/components/TailnetCard.tsx#TailnetConnectDialog",
  ],
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
      // retry-prompt-ok: the tailnet Try Again starts its sign-in again.
      "A failed start: acpmux's own text, and Try Again.",
    ),
    "cloud-off": {
      section: "devices",
      tailnet: { state: "stopped" },
      steps: [shown, { selector: '[data-tailnet-action="start"]', action: "focus" }],
      note: "Tailscale for Cloud machines off (the default): only this Mac's own tailnet card, no Join.",
    },
    "cloud-ready": {
      section: "devices",
      options: {
        values: { "tailnet.join.enabled": true, "tailnet.join.tags": ["tag:cmux"], "tailnet.join.ssh": true },
      },
      host: cloudHost,
      steps: [cloudShown, { selector: "[data-tailnet-vm-join]", action: "focus" }],
      note: "Tailscale is enabled for Cloud machines. Join opens a sheet that asks for a key only for this operation.",
    },
    "cloud-join-sheet": {
      section: "devices",
      options: { values: { "tailnet.join.enabled": true } },
      host: cloudHost,
      steps: openSheet,
      note: "The join sheet: Cloud machine, a password field, and the advice to use an ephemeral, single-use key.",
    },
    "cloud-joined": {
      section: "devices",
      options: { values: { "tailnet.join.enabled": true, "tailnet.join.tags": ["tag:cmux"] } },
      host: cloudHost,
      steps: [
        ...openSheet,
        ...fill("tskey-auth-kSINGLEUSE"),
        { selector: "[data-tailnet-join-submit]", action: "click" },
        { selector: "[data-tailnet-vm-leave]", action: "focus" },
      ],
      note: "Joined: the machine's MagicDNS name, online, its tailnet address and tags, and Leave.",
    },
    "cloud-reusable-key": {
      section: "devices",
      options: { values: { "tailnet.join.enabled": true } },
      host: cloudHost,
      steps: [...openSheet, ...fill("tskey-client-kREUSABLE")],
      note: "An OAuth client secret pasted: the sheet warns that it can join more than one machine.",
    },
    "cloud-plain-http": {
      section: "devices",
      options: { values: { "tailnet.join.enabled": true, "tailnet.join.loginServer": "http://headscale.lan:8080" } },
      host: cloudHost,
      steps: [...openSheet, ...fill("hskey-auth-0123")],
      note: "A plain-http Headscale server: Join stays off until Allow plain HTTP is ticked for that server.",
    },
    "cloud-connect-sheet": {
      section: "devices",
      options: { values: { "tailnet.join.enabled": true, "tailnet.join.tags": ["tag:cmux"] } },
      host: cloudHost,
      steps: openConnect,
      note: "RFD 0169 Connect Your Tailnet: Cloud machine, key, optional name, and the policy lines from `cmux vm tailnet acl` with Copy.",
    },
    "cloud-connect-copied": {
      section: "devices",
      options: { values: { "tailnet.join.enabled": true, "tailnet.join.tags": ["tag:cmux"] } },
      host: cloudHost,
      steps: [
        ...openConnect,
        ...connectFill("tskey-auth-kONCE"),
        { selector: "[data-tailnet-acl-copy]", action: "click" },
      ],
      note: "Filled in and the policy lines copied: Copy reads Copied, Connect is on.",
    },
    "cloud-connected": {
      section: "devices",
      options: { values: { "tailnet.join.enabled": true, "tailnet.join.tags": ["tag:cmux"] } },
      host: cloudHost,
      steps: [
        ...openConnect,
        ...connectFill("tskey-auth-kONCE"),
        { selector: "[data-tailnet-connect-submit]", action: "click" },
        { selector: "[data-tailnet-vm-leave]", action: "focus" },
      ],
      note: "Connected: the stable node YOU-cmux, online, tagged tag:cmux, and Leave; the Connect row steps aside.",
    },
    "cloud-connect-kept": {
      section: "devices",
      options: { values: { "tailnet.join.enabled": true, "tailnet.join.tags": ["tag:cmux"] } },
      host: cloudHost,
      steps: [
        ...openConnect,
        ...connectFill("tskey-auth-KEPT"),
        { selector: "[data-tailnet-connect-submit]", action: "click" },
      ],
      note: "The vault already keeps a node: the CLI's refusal names adopt, so no second device is made.",
    },
    "cloud-other-tailnet": {
      section: "devices",
      options: { values: { "tailnet.join.enabled": true } },
      host: cloudHost,
      steps: [...openSheet, ...fill("tskey-auth-kOTHER"), { selector: "[data-tailnet-join-submit]", action: "click" }],
      note: "The machine is already on another tailnet: the CLI's error, and the hint to switch.",
    },
  },
});
