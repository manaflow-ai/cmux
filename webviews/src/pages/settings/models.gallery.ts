// l10n-allow-file: gallery fixtures, not shipped UI.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { GALLERY_NOW } from "../../gallery/clock";
import { chatgptDeviceError, mockChatGPTDevice, mockModels } from "./mockModels";
import type { AccountsState } from "./ops";
import { ACCOUNT_LISTS } from "../shared/signIn/galleryFixtures";

const click = (selector: string): PageFixtureStep => ({ selector, action: "click" });
const input = (selector: string, value: string): PageFixtureStep => ({ selector, action: "input", value });
const wait = (selector: string): PageFixtureStep => ({ selector, action: "wait" });
const action = (id: string) => click(`[data-models-action="${id}"]`);
const secret = '[data-models-dialog] input[type="password"]';
const page: SettingsPageVariant = { section: "models", models: mockModels.empty };
const cloud: SettingsPageVariant = { section: "cloud", models: mockModels.empty };
const dialog = (
  provider: string,
  models = mockModels.empty,
  scope = provider === "claude" || provider === "chatgpt" ? cloud : page,
): SettingsPageVariant => ({
  ...scope,
  focus: `${scope.section === "cloud" ? "cloudModels" : "models"}.add.${provider}`,
  models,
});
const enterKey = [input(secret, "sk-ant-example"), action("addKey")];
const custom = [
  click("[data-models-add]"),
  click('[data-models-choice="endpoint"]'),
  input('[data-models-endpoint-form] input[type="text"]', "Inference"),
  input('[data-models-endpoint-form] input[type="url"]', "https://inference.example.com/v1"),
  input(secret, "example-key"),
];
// A host that signs in in place: it lists the sign-in accounts (the rest of Settings > Accounts is
// not on this page).
const signInHost: AccountsState = {
  teams: null,
  refresh: "Refresh",
  refreshing: false,
  cmux: {
    title: "cmux",
    detail: null,
    status: "Signed in",
    statusKind: "success",
    busy: false,
    buttons: [],
    note: null,
    error: null,
  },
  removeTitle: "Remove",
  groups: [],
  signInAccounts: [...ACCOUNT_LISTS.signedOut],
};
const cloudPlan = mockModels.chatgptForCloud.personal.connections.find((c) => c.kind === "chatgpt-plan")!;

export default settingsPageEntry({
  id: "pages.settings-models",
  title: "Settings Models",
  area: "Settings",
  height: 820,
  widths: { narrow: 446 },
  covers: [
    "pages/settings/components/ModelsCard.tsx#ModelsCard",
    "pages/settings/components/ModelConnectionRow.tsx#ModelConnectionRow",
    "pages/settings/components/ModelProviderPicker.tsx#ModelProviderPicker",
    "pages/settings/components/ModelConnectionDialog.tsx#ModelConnectionDialog",
    "pages/settings/components/ModelsCard.tsx#CloudModelsCard",
    "pages/settings/components/ChatGPTDevicePanel.tsx#ChatGPTDeviceForm",
    "pages/settings/components/ClaudeLoginForm.tsx#ClaudeLoginForm",
    "pages/settings/components/ModelEndpointForm.tsx#ModelEndpointForm",
    "pages/settings/components/ModelKeyForm.tsx#ModelKeyForm",
  ],
  variants: {
    empty: page,
    connections: { ...page, models: mockModels.macLogins },
    "row-menu": {
      ...page,
      models: mockModels.macLogins,
      steps: [click('[data-menu="connection-openrouter-key"]'), wait('[data-value="edit"]')],
    },
    "key-edit": {
      ...page,
      models: mockModels.macLogins,
      steps: [click('[data-menu="connection-openrouter-key"]'), click('[data-value="edit"]'), wait(secret)],
    },
    // Logins done right (Leo, 2026-11-22): on a host that signs in in place, the Claude login's
    // Sign In Again opens the card under the row.
    "claude-sign-in-in-place": {
      ...page,
      models: mockModels.macLogins,
      accounts: signInHost,
      signInHold: true,
      steps: [
        click('[data-menu="connection-claude-login"]'),
        click('[role="menuitem"][data-value="signInAgain"]'),
        wait('[data-connection-sign-in="claude-login"] .signin[data-state="waiting"]'),
      ],
    },
    "mac-only": { ...page, models: mockModels.macOnly },
    "signed-out": { ...page, models: mockModels.signedOut },
    dropdown: {
      ...page,
      models: mockModels.macOnly,
      steps: [click("[data-models-add]"), wait("[data-models-catalog]")],
    },
    "dropdown-search": { ...page, focus: "models.add", steps: [input('input[role="combobox"]', "deepseek")] },
    "anthropic-form": dialog("anthropic"),
    "openai-form": dialog("openai"),
    "api-checking": {
      ...dialog("anthropic"),
      modelAccessChecking: true,
      steps: [...enterKey, wait("[data-models-saving]")],
    },
    "api-refused": {
      ...dialog("anthropic"),
      steps: [...enterKey, wait("[data-models-dialog] [role=alert]")],
      options: { modelAccess: { failure: "The provider refused the key (HTTP 401)." } },
    },
    "api-saved": {
      ...dialog("anthropic"),
      steps: [...enterKey, wait('[data-connection="anthropic-key"]')],
    },
    "cloudflare-form": dialog("cloudflare"),
    "local-sign-in": {
      ...page,
      models: mockModels.macLogins,
      steps: [click('[data-menu="connection-claude-login"]'), click('[data-value="signInAgain"]')],
    },
    "cloud-empty": cloud,
    "cloud-connections": { ...cloud, models: mockModels.macLogins },
    "cloud-coming-soon": dialog("deepseek", { ...mockModels.empty, cloudHarnesses: [] }, cloud),
    "cloud-endpoint-toggle-error": {
      ...cloud,
      models: {
        ...mockModels.empty,
        cloudHarnesses: ["opencode"],
        personal: {
          ...mockModels.empty.personal,
          connections: [
            {
              id: "deepseek",
              label: "DeepSeek",
              kind: "endpoint",
              provider: "deepseek",
              families: ["deepseek"],
              email: null,
              plan: null,
              signedIn: true,
              enabled: true,
              defaultFor: [],
              servesCloud: true,
              canServeCloud: true,
              launchHarness: "opencode",
              endpoint: {
                kind: "openai-endpoint",
                preset: "deepseek",
                baseUrl: "https://api.deepseek.com",
                models: ["deepseek-chat"],
                revision: "1",
              },
            },
          ],
        },
      },
      endpoint: { addFails: "cmux.page.invalid_params" },
      steps: [
        click('[data-menu="connection-deepseek"]'),
        click('[data-value="setCloud"]'),
        wait('[data-card="cloudModels"] [role="alert"]'),
      ],
    },
    "cloud-key-form": dialog("openai", mockModels.empty, cloud),
    "cloud-key-menu": {
      ...cloud,
      models: mockModels.macLogins,
      steps: [click('[data-menu="connection-openrouter-key"]'), wait('[data-value="setCloud"]')],
    },
    "claude-form": dialog("claude"),
    "claude-approving": dialog("claude", mockModels.claudeApproving),
    "cloud-pending-setup": dialog("claude", {
      ...mockModels.empty,
      cloudClaudeLogin: { phase: "preparing", error: null },
    }),
    "claude-browser-code": dialog("claude", mockModels.claudeCode),
    "claude-cancelling": dialog("claude", mockModels.claudeCancelling),
    "claude-timed-out": dialog("claude", mockModels.claudeTimedOut),
    "claude-missing": dialog("claude", mockModels.claudeMissing),
    "claude-failed": dialog("claude", mockModels.claudeFailed),
    "claude-connected": {
      ...cloud,
      models: {
        ...mockModels.empty,
        cloudClaudeLogin: { phase: "connected", error: null },
      },
    },
    "claude-cloud-ready-to-connect": dialog("claude", {
      ...mockModels.empty,
      cloudClaudeLogin: { phase: "idle", error: null },
    }),
    "claude-cloud-start-failed": dialog("claude", {
      ...mockModels.empty,
      cloudClaudeLogin: { phase: "failed", error: "machine_start_failed" },
    }),
    "claude-shared-machine": dialog("claude", {
      ...mockModels.empty,
      cloudClaudeLogin: { phase: "disabled", error: "shared_machine" },
    }),
    "claude-update": dialog("claude", {
      ...mockModels.empty,
      cloudClaudeLogin: { phase: "disabled", error: "update_claude" },
    }),
    "claude-standalone": { ...cloud, models: mockModels.claudeTokenOnly },
    "chatgpt-form": dialog("chatgpt"),
    "chatgpt-starting": dialog("chatgpt", { ...mockModels.macOnly, chatgptDevice: { phase: "starting" } }),
    "chatgpt-approval": dialog("chatgpt", {
      ...mockModels.macOnly,
      chatgptDevice: mockChatGPTDevice(GALLERY_NOW / 1000 + 520),
    }),
    "chatgpt-cancelling": dialog("chatgpt", { ...mockModels.macOnly, chatgptDevice: { phase: "cancelling" } }),
    "chatgpt-signed-in": {
      ...dialog("chatgpt", mockModels.macOnly),
      options: {
        chatgptDeviceCompletion: {
          ...mockModels.chatgptForCloud,
          chatgptDevice: { phase: "connected", id: cloudPlan.id },
        },
      },
      steps: [action("connectChatGPTDevice"), wait('[data-chatgpt-device="connected"]')],
    },
    "chatgpt-reconnect": {
      ...cloud,
      models: {
        ...mockModels.empty,
        personal: { ...mockModels.empty.personal, connections: [cloudPlan] },
      },
      steps: [
        click(`[data-menu="connection-${cloudPlan.id}"]`),
        click('[data-value="signInAgain"]'),
        wait('[data-models-dialog="chatgpt"]'),
      ],
    },
    "chatgpt-denied": dialog("chatgpt", chatgptDeviceError("access_denied")),
    "chatgpt-expired": dialog("chatgpt", chatgptDeviceError("expired_token")),
    "chatgpt-network": dialog("chatgpt", chatgptDeviceError("network")),
    "chatgpt-already-connected": dialog("chatgpt", chatgptDeviceError("already_signed_in")),
    loading: { ...page, modelsLoading: true },
    unavailable: {
      ...page,
      models: { ...mockModels.empty, personal: { ...mockModels.empty.personal, available: false } },
    },
    "endpoint-rest": dialog("endpoint"),
    "endpoint-filled": { ...page, steps: custom },
    member: { ...page, models: mockModels.member },
  },
});
