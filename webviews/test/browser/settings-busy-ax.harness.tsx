// The real Settings page over the mock host with one card whose change a test holds in flight
// (`#card=library`, `card=shares` or `card=accounts`), for test/settings-busy-ax-browser.test.ts.
// `axHold()` makes the card's next change wait until `axAnswer()`, so only the card's busy state
// changes, on and off, while the browser's accessibility tree is already live.
import "../../src/pages/shared/desktop";
import "../../src/ui/ui.css";
import "../../src/pages/settings/page.css";
import "../../src/pages/settings/tailwind.css";
import { createRoot } from "react-dom/client";
import strings from "../../src/pages/settings/generated/strings.json";
import { SettingsPage } from "../../src/pages/settings/components/SettingsPage";
import { createMockClient } from "../../src/pages/settings/mockProvider";
import { mockLongLibrary } from "../../src/pages/settings/mockLibrary";
import type { ProviderAccount, SharesState } from "../../src/pages/settings/ops";
import { SettingsStore } from "../../src/pages/settings/store";
import { installCatalog, setLocale } from "../../src/pages/settings/strings";

declare global {
  interface Window {
    axReady: boolean;
    /** The card's rows. */
    axRowSelector: string;
    /** The card's next change waits until `axAnswer()`. */
    axHold(): void;
    axAnswer(): void;
    /** How many changes the card started since `axHold()`. */
    axCalls(): number;
  }
}

const params = new URLSearchParams(location.hash.slice(1));
const card = (["shares", "accounts"] as const).find((name) => name === params.get("card")) ?? "library";
const n = Number(params.get("n") ?? 200);
const NOW = Date.now();
const MINUTE = 60_000;

function shares(count: number): SharesState {
  const titles: Record<string, string> = {};
  return {
    available: true,
    titles,
    shares: Array.from({ length: count }, (_, index) => {
      titles[String(index)] = `Shared chat ${index}`;
      return {
        share_id: `sh_${String(index).padStart(6, "0")}`,
        state: "active",
        session: `s-${index}`,
        surface: index,
        created_at: NOW - (index + 1) * MINUTE,
        expires_at: NOW + 24 * 60 * MINUTE,
        uses_left: 0,
        guests: [],
        invitees: [],
      };
    }),
  };
}

const account = (id: string, name: string, extra: Partial<ProviderAccount> = {}): ProviderAccount => ({
  id,
  family: "codex",
  name,
  home: `~/.cmux/accounts/${id}`,
  defaultHome: "~/.codex",
  shadowOf: null,
  signedIn: true,
  plan: "pro",
  email: `${id}@example.com`,
  enabled: true,
  builtin: false,
  ...extra,
});

installCatalog(strings as Record<string, Record<string, string>>);
setLocale("en");
document.documentElement.dataset.settingsLook = "refined";
const { client, provider } = createMockClient();
if (card === "library") provider.library = mockLongLibrary(n);
else if (card === "shares") provider.shares = shares(n);
else
  provider.setHarnesses({
    ...provider.harnesses,
    accounts: [
      account("codex-login", "ChatGPT", { home: null, builtin: true }),
      account("codex-2", "ChatGPT 2", { shadowOf: "codex-login" }),
      account("codex-3", "ChatGPT 3", { signedIn: false }),
    ],
  });
location.hash = { library: "#/settings/personalization", shares: "#/settings/privacy", accounts: "#/settings/agents" }[
  card
];
const store = new SettingsStore(client);
createRoot(document.getElementById("root")!).render(<SettingsPage store={store} />);
window.axRowSelector = {
  library: '[data-card="customizeLibrary"] [data-library-entry]',
  shares: '[data-card="sharedLinks"] [data-shared-link]',
  accounts: '[data-card="harnesses"] [data-harness="codex"] [data-account]',
}[card];

let answer: () => void = () => {};
let calls = 0;
window.axHold = () => {
  calls = 0;
  const run = <T,>(value: T) => {
    calls += 1;
    return new Promise<T>((resolve) => (answer = () => resolve(value)));
  };
  if (card === "library") store.customizeLibrary = () => run({ library: null, refusal: null });
  else if (card === "shares") store.revokeShares = () => run(null);
  else store.runHarnesses = () => run({ ok: true as const, value: undefined });
};
window.axAnswer = () => answer();
window.axCalls = () => calls;
void store.start().then(() => {
  window.axReady = true;
});
