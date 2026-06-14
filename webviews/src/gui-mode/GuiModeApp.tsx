import React, { useCallback, useRef, useState } from "react";
import { Icon } from "../icons";
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
  const [providerQuery, setProviderQuery] = useState("");
  const [selectedProviderId, setSelectedProviderId] = useState(context.selectedProviderId);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState("");
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const selectedProvider = providerForId(context.providers, selectedProviderId);
  const filteredProviders = filterGuiModeProviders(context.providers, providerQuery);
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

  return h("section", { className: "gui-mode-home", "aria-label": context.copy.homeTitle },
    h("div", { className: "gui-mode-shell" },
      h("div", { className: "gui-mode-topline", style: accentStyle },
        h("div", { className: "gui-mode-title" }, context.copy.homeTitle),
        h("div", { className: "gui-mode-runtime-pill" }, selectedProvider.supportLabel),
      ),
      h("div", { className: `${CODEX_COMPOSER_STACK} gui-mode-center-stack` },
        h("div", { className: CODEX_COMPOSER_FRAME },
          h("div", { className: `${CODEX_COMPOSER_SURFACE} gui-mode-composer` },
            h("div", { className: CODEX_COMPOSER_INNER },
              h("div", { className: "gui-mode-provider-header" },
                h("div", { className: "gui-mode-provider-label" }, context.copy.providerLabel),
                h("div", { className: "gui-mode-provider-selected" },
                  h("span", { className: "gui-mode-provider-count" }, `${filteredProviders.length}/${context.providers.length}`),
                  h("span", { className: "gui-mode-provider-selected-name" }, selectedProvider.displayName),
                ),
              ),
              h("label", { className: "gui-mode-provider-search" },
                h("span", { className: "gui-mode-search-icon" }, h(Icon, { name: "search" })),
                h("input", {
                  "aria-label": context.copy.providerSearchPlaceholder,
                  className: "gui-mode-provider-search-input",
                  onInput: (event: React.FormEvent<HTMLInputElement>) => setProviderQuery(event.currentTarget.value),
                  placeholder: context.copy.providerSearchPlaceholder,
                  spellCheck: false,
                  type: "search",
                  value: providerQuery,
                }),
              ),
              h(ProviderPicker, {
                noProvidersFound: context.copy.noProvidersFound,
                providers: filteredProviders,
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
      h(ProviderSummary, {
        provider: selectedProvider,
        setupCommandLabel: context.copy.setupCommandLabel,
        taskCommandLabel: context.copy.taskCommandLabel,
      }),
    ),
  );
}

function GuiModeTaskPage({ context }: { context: GuiModeContext }) {
  const provider = providerForId(context.providers, context.selectedProviderId);
  return h("section", {
    "aria-label": context.copy.taskTitle,
    className: "gui-mode-task",
    style: providerAccentStyle(provider),
  },
    h("div", { className: "gui-mode-task-panel" },
      h("div", { className: "gui-mode-task-provider" },
        h("div", { className: "gui-mode-task-provider-heading" },
          h("span", { className: "gui-mode-provider-mark", "aria-hidden": "true" }),
          h("div", { className: "gui-mode-task-provider-name" }, provider.displayName),
          h("div", { className: "gui-mode-task-support" }, provider.supportLabel),
        ),
        h("div", { className: "gui-mode-task-provider-detail" }, provider.detail),
        h("div", { className: "gui-mode-task-chips" },
          provider.capabilities.map((capability) => h("span", {
            className: "gui-mode-task-chip",
            key: capability,
          }, capability)),
        ),
        h("div", { className: "gui-mode-command-row gui-mode-task-command-row" },
          h("span", { className: "gui-mode-command-label" }, context.copy.taskCommandLabel),
          h("code", { className: "gui-mode-command-code gui-mode-task-command" }, provider.taskCommandPreview),
        ),
      ),
      h("div", { className: "gui-mode-task-label" }, context.copy.taskPromptLabel),
      h("div", { className: "gui-mode-task-prompt" }, context.prompt),
    ),
  );
}

function ProviderPicker({
  onSelectProvider,
  noProvidersFound,
  providers,
  selectedProviderId,
}: {
  onSelectProvider: (providerId: string) => void;
  noProvidersFound: string;
  providers: GuiModeProvider[];
  selectedProviderId: string;
}) {
  return h("div", { className: "gui-mode-provider-grid", role: "listbox" },
    providers.length === 0
      ? h("div", { className: "gui-mode-provider-empty", role: "status" }, noProvidersFound)
      : null,
    providers.map((provider) => h("button", {
      "aria-selected": provider.id === selectedProviderId,
      className: "gui-mode-provider-option",
      "data-provider-id": provider.id,
      key: provider.id,
      onClick: () => onSelectProvider(provider.id),
      role: "option",
      style: providerAccentStyle(provider),
      type: "button",
    },
      h("span", { className: "gui-mode-provider-option-top" },
        h("span", { className: "gui-mode-provider-mark", "aria-hidden": "true" }),
        h("span", { className: "gui-mode-provider-name" }, provider.displayName),
        h("span", { className: "gui-mode-provider-support" }, provider.supportLabel),
      ),
      h("span", { className: "gui-mode-provider-detail" }, provider.detail),
    )),
  );
}

function ProviderSummary({
  provider,
  setupCommandLabel,
  taskCommandLabel,
}: {
  provider: GuiModeProvider;
  setupCommandLabel: string;
  taskCommandLabel: string;
}) {
  return h("aside", { className: "gui-mode-provider-summary", style: providerAccentStyle(provider) },
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
    h("div", { className: "gui-mode-command-grid" },
      h("div", { className: "gui-mode-command-row" },
        h("span", { className: "gui-mode-command-label" }, setupCommandLabel),
        h("code", { className: "gui-mode-command-code" }, provider.setupCommand),
      ),
      h("div", { className: "gui-mode-command-row" },
        h("span", { className: "gui-mode-command-label" }, taskCommandLabel),
        h("code", { className: "gui-mode-command-code" }, provider.taskCommandPreview),
      ),
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
