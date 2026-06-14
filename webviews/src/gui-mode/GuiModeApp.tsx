import React, { useCallback, useRef, useState } from "react";
import {
  CODEX_BUTTON_BASE,
  CODEX_BUTTON_COMPOSER,
  CODEX_BUTTON_PRIMARY,
  CODEX_COMPOSER_FRAME,
  CODEX_COMPOSER_INNER,
  CODEX_COMPOSER_STACK,
  CODEX_COMPOSER_SURFACE,
} from "../agent-session/shared/codexClassNames";
import {
  PromptEditor,
  type PromptEditorHandle,
} from "../agent-session/react/proseMirrorPromptEditor";
import {
  loadGuiModeContext,
  submitGuiModePrompt,
  type GuiModeContext,
  type GuiModeProvider,
} from "./bridge";

const h = React.createElement;

type LoadState =
  | { status: "ready"; context: GuiModeContext }
  | { status: "error"; message: string };

function fallbackProvider(
  id: string,
  displayName: string,
  detail: string,
  runtimeMode: string,
  supportLabel: string,
  capabilities: string[],
): GuiModeProvider {
  return {
    capabilities,
    detail,
    displayName,
    id,
    runtimeMode,
    setupCommand: id === "claude" ? "claude auth login" : `cmux hooks ${id} install`,
    supportLabel,
    taskCommandPreview: `/task-worktree-pr --provider ${id}`,
  };
}

const fallbackProviders: GuiModeProvider[] = [
  fallbackProvider("codex", "Codex", "Native session with hook telemetry", "native-hooks", "Native + hooks", ["Native session", "Hook telemetry", "Restorable"]),
  fallbackProvider("claude", "Claude Code", "Native cmux session", "native", "Native", ["Native session", "Restorable"]),
  fallbackProvider("opencode", "OpenCode", "Native session with hook telemetry", "native-hooks", "Native + hooks", ["Native session", "Hook telemetry", "Restorable"]),
  fallbackProvider("grok", "Grok", "Vault-registered hook agent", "vault-hooks", "Vault + hooks", ["Hook telemetry", "Vault registry", "Restorable"]),
  fallbackProvider("pi", "Pi", "Vault-registered hook agent", "vault-hooks", "Vault + hooks", ["Hook telemetry", "Vault registry", "Restorable"]),
  fallbackProvider("omp", "OMP", "Vault-registered hook agent", "vault-hooks", "Vault + hooks", ["Hook telemetry", "Vault registry"]),
  fallbackProvider("amp", "Amp", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
  fallbackProvider("cursor", "Cursor", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
  fallbackProvider("gemini", "Gemini", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
  fallbackProvider("kiro", "Kiro", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
  fallbackProvider("antigravity", "Antigravity", "Vault-registered hook agent", "vault-hooks", "Vault + hooks", ["Hook telemetry", "Vault registry", "Restorable"]),
  fallbackProvider("rovodev", "Rovo Dev", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
  fallbackProvider("hermes-agent", "Hermes Agent", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
  fallbackProvider("copilot", "Copilot", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
  fallbackProvider("codebuddy", "CodeBuddy", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
  fallbackProvider("factory", "Factory", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
  fallbackProvider("qoder", "Qoder", "Hook-backed agent", "hooks", "Hooks", ["Hook telemetry", "Restorable"]),
];

const defaultContext: GuiModeContext = {
  copy: {
    errorMessage: "Could not create the GUI workspace.",
    homeTitle: "GUI Mode",
    promptPlaceholder: "What should cmux build?",
    providerLabel: "Agent",
    runtimeLabel: "Runtime",
    submit: "Submit",
    submitting: "Submitting",
    taskPromptLabel: "Prompt",
    taskTitle: "/task-worktree-pr",
  },
  page: "home",
  prompt: "",
  providers: fallbackProviders,
  selectedProviderId: "codex",
};

export function GuiModeApp() {
  const [loadState, setLoadState] = useState<LoadState>({ status: "ready", context: defaultContext });
  const didRequestContext = useRef(false);
  const loadHostRef = useCallback((node: HTMLElement | null) => {
    if (!node || didRequestContext.current) {
      return;
    }
    didRequestContext.current = true;
    void loadGuiModeContext()
      .then((context) => {
        syncGuiModeRoute(context);
        setLoadState({ status: "ready", context });
      })
      .catch((error) => {
        const message = error instanceof Error ? error.message : "Native bridge unavailable.";
        setLoadState({ status: "error", message });
      });
  }, []);

  if (loadState.status === "ready") {
    return h("main", { ref: loadHostRef, className: "gui-mode-root" },
      loadState.context.page === "task-worktree-pr"
        ? h(GuiModeTaskPage, { context: loadState.context })
        : h(GuiModeHomePage, { context: loadState.context, key: loadState.context.selectedProviderId }),
    );
  }

  return h("main", { ref: loadHostRef, className: "gui-mode-root" },
    h("div", { className: "gui-mode-status", role: "alert" }, loadState.message),
  );
}

function syncGuiModeRoute(context: GuiModeContext): void {
  const expectedHash = context.page === "task-worktree-pr" ? "#/task-worktree-pr" : "#/gui-mode";
  if (window.location.hash === expectedHash) {
    return;
  }
  window.history.replaceState(
    null,
    "",
    `${window.location.pathname}${window.location.search}${expectedHash}`,
  );
}

function GuiModeHomePage({ context }: { context: GuiModeContext }) {
  const [prompt, setPrompt] = useState("");
  const [selectedProviderId, setSelectedProviderId] = useState(context.selectedProviderId);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState("");
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const selectedProvider = providerForId(context.providers, selectedProviderId);
  const trimmedPrompt = prompt.trim();
  const canSubmit = trimmedPrompt.length > 0 && !isSubmitting;
  const submit = useCallback(() => {
    if (!canSubmit) {
      return;
    }
    setIsSubmitting(true);
    setError("");
    void submitGuiModePrompt(trimmedPrompt, selectedProvider.id)
      .catch(() => setError(context.copy.errorMessage))
      .finally(() => setIsSubmitting(false));
  }, [canSubmit, context.copy.errorMessage, selectedProvider.id, trimmedPrompt]);

  return h("section", { className: "gui-mode-home", "aria-label": context.copy.homeTitle },
    h("div", { className: "gui-mode-shell" },
      h("div", { className: "gui-mode-topline" },
        h("div", { className: "gui-mode-title" }, context.copy.homeTitle),
        h("div", { className: "gui-mode-runtime-pill" }, selectedProvider.supportLabel),
      ),
      h("div", { className: `${CODEX_COMPOSER_STACK} gui-mode-center-stack` },
        h("div", { className: CODEX_COMPOSER_FRAME },
          h("div", { className: `${CODEX_COMPOSER_SURFACE} gui-mode-composer` },
            h("div", { className: CODEX_COMPOSER_INNER },
              h("div", { className: "gui-mode-provider-header" },
                h("div", { className: "gui-mode-provider-label" }, context.copy.providerLabel),
                h("div", { className: "gui-mode-provider-selected" }, selectedProvider.displayName),
              ),
              h(ProviderPicker, {
                providers: context.providers,
                selectedProviderId: selectedProvider.id,
                onSelectProvider: setSelectedProviderId,
              }),
              h(PromptEditor, {
                ref: editorRef,
                ariaLabel: context.copy.promptPlaceholder,
                className: "gui-mode-editor",
                minHeight: "6.25rem",
                onSubmit: submit,
                onTextChange: setPrompt,
                placeholder: context.copy.promptPlaceholder,
                value: prompt,
              }),
              h("div", { className: "gui-mode-footer" },
                h("div", { className: "gui-mode-error", role: "alert" }, error),
                h("button", {
                  className: `${CODEX_BUTTON_BASE} ${CODEX_BUTTON_PRIMARY} ${CODEX_BUTTON_COMPOSER} gui-mode-submit`,
                  disabled: !canSubmit,
                  onClick: submit,
                  type: "button",
                }, isSubmitting ? context.copy.submitting : context.copy.submit),
              ),
            ),
          ),
        ),
      ),
      h(ProviderSummary, { provider: selectedProvider }),
    ),
  );
}

function GuiModeTaskPage({ context }: { context: GuiModeContext }) {
  const provider = providerForId(context.providers, context.selectedProviderId);
  return h("section", { className: "gui-mode-task", "aria-label": context.copy.taskTitle },
    h("div", { className: "gui-mode-task-panel" },
      h("div", { className: "gui-mode-task-provider" },
        h("div", { className: "gui-mode-task-provider-name" }, provider.displayName),
        h("div", { className: "gui-mode-task-provider-detail" }, provider.detail),
        h("div", { className: "gui-mode-task-command" }, provider.taskCommandPreview),
      ),
      h("div", { className: "gui-mode-task-label" }, context.copy.taskPromptLabel),
      h("div", { className: "gui-mode-task-prompt" }, context.prompt),
    ),
  );
}

function ProviderPicker({
  onSelectProvider,
  providers,
  selectedProviderId,
}: {
  onSelectProvider: (providerId: string) => void;
  providers: GuiModeProvider[];
  selectedProviderId: string;
}) {
  return h("div", { className: "gui-mode-provider-grid", role: "listbox" },
    providers.map((provider) => h("button", {
      "aria-selected": provider.id === selectedProviderId,
      className: "gui-mode-provider-option",
      key: provider.id,
      onClick: () => onSelectProvider(provider.id),
      role: "option",
      type: "button",
    },
      h("span", { className: "gui-mode-provider-option-top" },
        h("span", { className: "gui-mode-provider-name" }, provider.displayName),
        h("span", { className: "gui-mode-provider-support" }, provider.supportLabel),
      ),
      h("span", { className: "gui-mode-provider-detail" }, provider.detail),
    )),
  );
}

function ProviderSummary({ provider }: { provider: GuiModeProvider }) {
  return h("aside", { className: "gui-mode-provider-summary" },
    h("div", { className: "gui-mode-summary-main" },
      h("div", { className: "gui-mode-summary-name" }, provider.displayName),
      h("div", { className: "gui-mode-summary-detail" }, provider.detail),
    ),
    h("div", { className: "gui-mode-summary-chips" },
      provider.capabilities.map((capability) => h("span", {
        className: "gui-mode-summary-chip",
        key: capability,
      }, capability)),
    ),
    h("div", { className: "gui-mode-summary-command" }, provider.setupCommand),
  );
}

function providerForId(providers: GuiModeProvider[], providerId: string): GuiModeProvider {
  return providers.find((provider) => provider.id === providerId) ?? providers[0] ?? {
    detail: "",
    displayName: providerId,
    id: providerId,
    runtimeMode: "",
    setupCommand: "",
    supportLabel: "",
    taskCommandPreview: "",
    capabilities: [],
  };
}
