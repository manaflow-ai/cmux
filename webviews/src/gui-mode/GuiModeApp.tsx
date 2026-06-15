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
import { guiModeFallbackProviders } from "./providerCatalog";

const h = React.createElement;

type LoadState =
  | { status: "ready"; context: GuiModeContext }
  | { status: "error"; message: string };

const defaultContext: GuiModeContext = {
  copy: {
    errorMessage: "Could not create the GUI workspace.",
    homeTitle: "GUI Mode",
    noProvidersFound: "No agents found",
    promptPlaceholder: "What should cmux build?",
    providerLabel: "Agent",
    providerSearchPlaceholder: "Search agents",
    runtimeLabel: "Runtime",
    setupCommandLabel: "Setup",
    submit: "Submit",
    submitting: "Submitting",
    taskCommandLabel: "Launch",
    taskPromptLabel: "Prompt",
    taskTitle: "/task-worktree-pr",
  },
  page: "home",
  prompt: "",
  providers: guiModeFallbackProviders,
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
        setLoadState({ status: "ready", context });
      })
      .catch((error) => {
        const message = error instanceof Error ? error.message : "Native bridge unavailable.";
        setLoadState({ status: "error", message });
      });
  }, []);

  if (loadState.status === "ready") {
    return h("main", {
      ref: loadHostRef,
      className: "gui-mode-root",
      "data-gui-mode-page": loadState.context.page,
      "data-gui-mode-provider": loadState.context.selectedProviderId,
      "data-gui-mode-prompt-length": String(loadState.context.prompt.length),
    },
      loadState.context.page === "task-worktree-pr"
        ? h(GuiModeTaskPage, { context: loadState.context })
        : h(GuiModeHomePage, { context: loadState.context, key: loadState.context.selectedProviderId }),
    );
  }

  return h("main", {
    ref: loadHostRef,
    className: "gui-mode-root",
    "data-gui-mode-page": "error",
  },
    h("div", { className: "gui-mode-status", role: "alert" }, loadState.message),
  );
}

function GuiModeHomePage({ context }: { context: GuiModeContext }) {
  const [prompt, setPrompt] = useState("");
  const [selectedProviderId, setSelectedProviderId] = useState(context.selectedProviderId);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState("");
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const selectedProvider = providerForId(context.providers, selectedProviderId);
  const accentStyle = providerAccentStyle(selectedProvider);
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

  return h("section", { className: "gui-mode-home", "aria-label": context.copy.homeTitle, style: accentStyle },
    h("div", { className: "gui-mode-chat-shell" },
      h("div", { className: "gui-mode-topline" },
        h("div", { className: "gui-mode-title" }, context.copy.homeTitle),
        h("div", { className: "gui-mode-runtime-pill" }, selectedProvider.supportLabel),
      ),
      h("div", { className: "gui-mode-chat-thread", role: "log", "aria-live": "polite" },
        h(AssistantChatTurn, {
          provider: selectedProvider,
          text: context.copy.promptPlaceholder,
        }),
        trimmedPrompt.length > 0
          ? h(UserChatTurn, { text: prompt })
          : null,
      ),
      h("div", { className: `${CODEX_COMPOSER_STACK} gui-mode-center-stack` },
        h("div", { className: CODEX_COMPOSER_FRAME },
          h("div", { className: `${CODEX_COMPOSER_SURFACE} gui-mode-composer` },
            h("div", { className: CODEX_COMPOSER_INNER },
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
                h("div", { className: "gui-mode-footer-left" },
                  h(ProviderSelect, {
                    label: context.copy.providerLabel,
                    providers: context.providers,
                    selectedProviderId: selectedProvider.id,
                    onSelectProvider: setSelectedProviderId,
                  }),
                  h("div", { className: "gui-mode-command-hint" },
                    h("span", { className: "gui-mode-command-label" }, context.copy.taskCommandLabel),
                    h("code", { className: "gui-mode-command-code" }, selectedProvider.taskCommandPreview),
                  ),
                ),
                h("button", {
                  className: `${CODEX_BUTTON_BASE} ${CODEX_BUTTON_PRIMARY} ${CODEX_BUTTON_COMPOSER} gui-mode-submit`,
                  disabled: !canSubmit,
                  onClick: submit,
                  type: "button",
                }, isSubmitting ? context.copy.submitting : context.copy.submit),
              ),
              h("div", { className: "gui-mode-error", role: "alert" }, error),
            ),
          ),
        ),
      ),
    ),
  );
}

function GuiModeTaskPage({ context }: { context: GuiModeContext }) {
  const provider = providerForId(context.providers, context.selectedProviderId);
  return h("section", {
    "aria-label": context.copy.taskTitle,
    className: "gui-mode-task gui-mode-task-chat",
    style: providerAccentStyle(provider),
  },
    h("div", { className: "gui-mode-chat-shell gui-mode-task-shell" },
      h("div", { className: "gui-mode-topline" },
        h("div", { className: "gui-mode-title" }, context.copy.taskTitle),
        h("div", { className: "gui-mode-runtime-pill" }, provider.displayName),
      ),
      h("div", { className: "gui-mode-chat-thread gui-mode-task-thread", role: "log" },
        h(UserChatTurn, { label: context.copy.taskPromptLabel, text: context.prompt }),
        h(AssistantChatTurn, {
          provider,
          text: provider.detail,
          commandLabel: context.copy.taskCommandLabel,
          command: provider.taskCommandPreview,
          capabilities: provider.capabilities,
        }),
      ),
    ),
  );
}

function ProviderSelect({
  label,
  onSelectProvider,
  providers,
  selectedProviderId,
}: {
  label: string;
  onSelectProvider: (providerId: string) => void;
  providers: GuiModeProvider[];
  selectedProviderId: string;
}) {
  const selectedProvider = providerForId(providers, selectedProviderId);
  return h("label", { className: "gui-mode-agent-select-shell", style: providerAccentStyle(selectedProvider) },
    h("span", { className: "gui-mode-provider-mark", "aria-hidden": "true" }),
    h("span", { className: "gui-mode-agent-select-label" }, label),
    h("select", {
      "aria-label": label,
      className: "gui-mode-agent-select",
      onChange: (event: React.ChangeEvent<HTMLSelectElement>) => onSelectProvider(event.currentTarget.value),
      value: selectedProvider.id,
    },
      providers.map((provider) => h("option", {
        key: provider.id,
        value: provider.id,
      }, provider.displayName)),
    ),
  );
}

function AssistantChatTurn({
  capabilities = [],
  command,
  commandLabel,
  provider,
  text,
}: {
  capabilities?: string[];
  command?: string;
  commandLabel?: string;
  provider: GuiModeProvider;
  text: string;
}) {
  return h("div", { className: "gui-mode-chat-turn gui-mode-chat-turn-assistant" },
    h("div", { className: "gui-mode-chat-avatar", style: providerAccentStyle(provider), "aria-hidden": "true" },
      h("span", { className: "gui-mode-provider-mark" }),
    ),
    h("div", { className: "gui-mode-chat-message gui-mode-assistant-message" },
      h("div", { className: "gui-mode-chat-message-head" },
        h("span", { className: "gui-mode-chat-agent-name" }, provider.displayName),
        h("span", { className: "gui-mode-chat-agent-support" }, provider.supportLabel),
      ),
      h("div", { className: "gui-mode-chat-message-text" }, text),
      capabilities.length > 0
        ? h("div", { className: "gui-mode-task-chips" },
          capabilities.map((capability) => h("span", {
            className: "gui-mode-task-chip",
            key: capability,
          }, capability)),
        )
        : null,
      command && commandLabel
        ? h("div", { className: "gui-mode-command-row gui-mode-task-command-row" },
          h("span", { className: "gui-mode-command-label" }, commandLabel),
          h("code", { className: "gui-mode-command-code gui-mode-task-command" }, command),
        )
        : null,
    ),
  );
}

function UserChatTurn({ label, text }: { label?: string; text: string }) {
  return h("div", { className: "gui-mode-chat-turn gui-mode-chat-turn-user" },
    h("div", { className: "gui-mode-chat-message gui-mode-user-message" },
      label ? h("div", { className: "gui-mode-chat-user-label" }, label) : null,
      h("div", { className: "gui-mode-chat-message-text" }, text),
    ),
  );
}

function providerForId(providers: GuiModeProvider[], providerId: string): GuiModeProvider {
  return providers.find((provider) => provider.id === providerId) ?? providers[0] ?? {
    accentColor: "#8b949e",
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

export function filterGuiModeProviders(providers: GuiModeProvider[], query: string): GuiModeProvider[] {
  const normalizedQuery = normalizeProviderSearchText(query);
  if (normalizedQuery.length === 0) {
    return providers;
  }
  const queryTokens = searchTokens(normalizedQuery);
  return providers.filter((provider) => {
    const searchable = [
      provider.id,
      provider.displayName,
      provider.detail,
      provider.runtimeMode,
      provider.supportLabel,
      provider.setupCommand,
      provider.taskCommandPreview,
      provider.capabilities.join(" "),
    ].join(" ");
    const normalizedSearchable = normalizeProviderSearchText(searchable);
    if (normalizedQuery.length >= 3 && normalizedSearchable.includes(normalizedQuery)) {
      return true;
    }
    const providerTokens = searchTokens(normalizedSearchable);
    return queryTokens.every((queryToken) =>
      providerTokens.some((providerToken) => providerToken.startsWith(queryToken))
    );
  });
}

function normalizeProviderSearchText(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function searchTokens(value: string): string[] {
  return value.split(/[^a-z0-9]+/).filter(Boolean);
}

function providerAccentStyle(provider: GuiModeProvider): React.CSSProperties {
  return {
    "--gui-provider-accent": provider.accentColor,
  } as React.CSSProperties;
}
