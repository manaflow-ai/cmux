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

const fallbackProviders: GuiModeProvider[] = [
  { detail: "Native cmux session", displayName: "Codex", id: "codex", runtimeMode: "native" },
  { detail: "Native cmux session", displayName: "Claude Code", id: "claude", runtimeMode: "native" },
  { detail: "Native cmux session", displayName: "OpenCode", id: "opencode", runtimeMode: "native" },
  { detail: "Hook-backed terminal", displayName: "Grok", id: "grok", runtimeMode: "hooks" },
  { detail: "Plugin-backed terminal", displayName: "Pi", id: "pi", runtimeMode: "plugin" },
  { detail: "Plugin-backed terminal", displayName: "OMP", id: "omp", runtimeMode: "plugin" },
  { detail: "Plugin-backed terminal", displayName: "Amp", id: "amp", runtimeMode: "plugin" },
  { detail: "Plugin-backed terminal", displayName: "Cursor", id: "cursor", runtimeMode: "plugin" },
  { detail: "Hook-backed terminal", displayName: "Gemini", id: "gemini", runtimeMode: "hooks" },
  { detail: "Hook-backed terminal", displayName: "Kiro", id: "kiro", runtimeMode: "hooks" },
  { detail: "Hook-backed terminal", displayName: "Antigravity", id: "antigravity", runtimeMode: "hooks" },
  { detail: "Hook-backed terminal", displayName: "Rovo Dev", id: "rovodev", runtimeMode: "hooks" },
  { detail: "Hook-backed terminal", displayName: "Hermes Agent", id: "hermes-agent", runtimeMode: "hooks" },
  { detail: "Hook-backed terminal", displayName: "Copilot", id: "copilot", runtimeMode: "hooks" },
  { detail: "Hook-backed terminal", displayName: "CodeBuddy", id: "codebuddy", runtimeMode: "hooks" },
  { detail: "Hook-backed terminal", displayName: "Factory", id: "factory", runtimeMode: "hooks" },
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
    h("div", { className: CODEX_COMPOSER_STACK },
      h("div", { className: CODEX_COMPOSER_FRAME },
        h("div", { className: `${CODEX_COMPOSER_SURFACE} gui-mode-composer` },
          h("div", { className: CODEX_COMPOSER_INNER },
            h("div", { className: "gui-mode-provider-header" },
              h("div", { className: "gui-mode-provider-label" }, context.copy.providerLabel),
              h("div", { className: "gui-mode-runtime-pill" },
                `${context.copy.runtimeLabel}: ${selectedProvider.runtimeMode}`,
              ),
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
              minHeight: "5.5rem",
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
  );
}

function GuiModeTaskPage({ context }: { context: GuiModeContext }) {
  const provider = providerForId(context.providers, context.selectedProviderId);
  return h("section", { className: "gui-mode-task", "aria-label": context.copy.taskTitle },
    h("div", { className: "gui-mode-task-panel" },
      h("div", { className: "gui-mode-task-provider" },
        h("div", { className: "gui-mode-task-provider-name" }, provider.displayName),
        h("div", { className: "gui-mode-task-provider-detail" }, provider.detail),
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
      h("span", { className: "gui-mode-provider-name" }, provider.displayName),
      h("span", { className: "gui-mode-provider-detail" }, provider.detail),
    )),
  );
}

function providerForId(providers: GuiModeProvider[], providerId: string): GuiModeProvider {
  return providers.find((provider) => provider.id === providerId) ?? providers[0] ?? {
    detail: "",
    displayName: providerId,
    id: providerId,
    runtimeMode: "",
  };
}
