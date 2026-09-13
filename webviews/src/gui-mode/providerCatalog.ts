import type { GuiModeProvider } from "./bridge";

type FallbackProviderInput = {
  accentColor: string;
  capabilities: string[];
  detail: string;
  displayName: string;
  id: string;
  runtimeMode: string;
  supportLabel: string;
};

function fallbackProvider(input: FallbackProviderInput): GuiModeProvider {
  return {
    ...input,
    setupCommand: input.id === "claude" ? "claude auth login" : `cmux hooks ${input.id} install`,
    taskCommandPreview: `/task-worktree-pr --provider ${input.id}`,
  };
}

export const guiModeFallbackProviders: GuiModeProvider[] = [
  fallbackProvider({
    id: "codex",
    displayName: "Codex",
    accentColor: "#22c55e",
    detail: "Native session with hook telemetry",
    runtimeMode: "native-hooks",
    supportLabel: "Native + hooks",
    capabilities: ["Native session", "Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "claude",
    displayName: "Claude Code",
    accentColor: "#d97706",
    detail: "Native cmux session",
    runtimeMode: "native",
    supportLabel: "Native",
    capabilities: ["Native session", "Restorable"],
  }),
  fallbackProvider({
    id: "opencode",
    displayName: "OpenCode",
    accentColor: "#38bdf8",
    detail: "Native session with hook telemetry",
    runtimeMode: "native-hooks",
    supportLabel: "Native + hooks",
    capabilities: ["Native session", "Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "grok",
    displayName: "Grok",
    accentColor: "#f43f5e",
    detail: "Vault-registered hook agent",
    runtimeMode: "vault-hooks",
    supportLabel: "Vault + hooks",
    capabilities: ["Hook telemetry", "Vault registry", "Restorable"],
  }),
  fallbackProvider({
    id: "pi",
    displayName: "Pi",
    accentColor: "#a78bfa",
    detail: "Vault-registered hook agent",
    runtimeMode: "vault-hooks",
    supportLabel: "Vault + hooks",
    capabilities: ["Hook telemetry", "Vault registry", "Restorable"],
  }),
  fallbackProvider({
    id: "omp",
    displayName: "OMP",
    accentColor: "#f59e0b",
    detail: "Vault-registered hook agent",
    runtimeMode: "vault-hooks",
    supportLabel: "Vault + hooks",
    capabilities: ["Hook telemetry", "Vault registry"],
  }),
  fallbackProvider({
    id: "amp",
    displayName: "Amp",
    accentColor: "#14b8a6",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "cursor",
    displayName: "Cursor",
    accentColor: "#60a5fa",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "gemini",
    displayName: "Gemini",
    accentColor: "#818cf8",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "kiro",
    displayName: "Kiro",
    accentColor: "#f97316",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "antigravity",
    displayName: "Antigravity",
    accentColor: "#e879f9",
    detail: "Vault-registered hook agent",
    runtimeMode: "vault-hooks",
    supportLabel: "Vault + hooks",
    capabilities: ["Hook telemetry", "Vault registry", "Restorable"],
  }),
  fallbackProvider({
    id: "rovodev",
    displayName: "Rovo Dev",
    accentColor: "#0ea5e9",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "hermes-agent",
    displayName: "Hermes Agent",
    accentColor: "#34d399",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "copilot",
    displayName: "Copilot",
    accentColor: "#10b981",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "codebuddy",
    displayName: "CodeBuddy",
    accentColor: "#fb7185",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "factory",
    displayName: "Factory",
    accentColor: "#facc15",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
  fallbackProvider({
    id: "qoder",
    displayName: "Qoder",
    accentColor: "#c084fc",
    detail: "Hook-backed agent",
    runtimeMode: "hooks",
    supportLabel: "Hooks",
    capabilities: ["Hook telemetry", "Restorable"],
  }),
];

export const guiModeFallbackProviderIds = guiModeFallbackProviders.map((provider) => provider.id);
