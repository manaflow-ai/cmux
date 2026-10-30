// A model the person cannot use is never a dead end (Leo 2026-10-26: "if user picks a model they
// don't have api key, we offer them to add credits or add their own api key"). The app's own ways
// in, run on the person's click in the pane (AgentPaneModel+Actions.swift accessActions):
//   - Add Credits…: the one paid-plan path every paywall takes (PaidPlanUpgrade, source inference):
//     Checkout on cmux.com that returns to this app, else the pricing page.
//   - Add API Key…: Settings > Accounts, at the paste field of the provider the chat's harness runs
//     on (else Accounts itself), where Send to CodeRouter (or Save to Keychain, then Connect) gives
//     the cmux model router the person's own key. Only the router reads a key saved there.
// Where they show: a failed turn the cmux model router refused for want of credits (failureCopy.ts
// `needs-credits`) offers both. A signed-out local harness in the model picker offers Log In, then
// Add Credits…, and never Add API Key…: acpmux starts Claude Code, Codex or Gemini with the login
// shell's environment and the harness's own sign-in, and nothing hands it a key saved in Accounts
// (cmux's Keychain item is read only to send it to CodeRouter, ProviderKeyStore.swift; a harness's
// own key lives in its acpmux profile's env, `cmux harness secret set`, which a built-in harness's
// profile cannot take from the app). Its own Log In is the way in that works.

/// The app actions behind the offer. The host runs them only on the person's gesture in the pane.
export const ACCESS_ACTIONS = { addKey: "accounts.show", addCredits: "palette.pro.upgrade" } as const;

/// The offer as the pane wires it: `addKey` takes the acpmux harness id (`claude`, `codex-work`, ...)
/// of the router-refused chat, whose provider's key field opens; undefined opens Accounts at the top.
export type AccessOffer = {
  addKey(harness?: string): void;
  addCredits(): void;
};

/// The Accounts provider (CmuxNextCodeRouter AIProvider raw value) whose API key a harness family runs on.
const KEY_PROVIDERS: Readonly<Record<string, string>> = { claude: "anthropic", codex: "openai", gemini: "gemini" };

/// The provider whose API key field "Add API Key…" opens for `harness`: its family, the id's first
/// word (`claude-sr` is Claude Code's), else none (the cmux model router's own harness, a custom one).
export function keyProvider(harness: string | undefined): string | undefined {
  if (!harness) return undefined;
  const family = harness.toLowerCase().split(/[-_.]/)[0] ?? "";
  return Object.hasOwn(KEY_PROVIDERS, family) ? KEY_PROVIDERS[family] : undefined;
}

/// The `action.run` params for "Add API Key…" on `harness`.
export function addKeyParams(harness: string | undefined): { id: string; provider?: string } {
  const provider = keyProvider(harness);
  return { id: ACCESS_ACTIONS.addKey, ...(provider ? { provider } : {}) };
}
