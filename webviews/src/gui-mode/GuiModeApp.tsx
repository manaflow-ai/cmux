import React, { useCallback, useRef, useState } from "react";
import {
  CODEX_BUTTON_BASE,
  CODEX_BUTTON_COMPOSER,
  CODEX_BUTTON_GHOST,
  CODEX_BUTTON_UNIFORM,
  CODEX_COMPOSER_FRAME,
  CODEX_COMPOSER_INNER,
  CODEX_COMPOSER_STACK,
  CODEX_COMPOSER_SURFACE,
  CODEX_SUBMIT_BUTTON,
} from "../agent-session/shared/codexClassNames";
import {
  PromptEditor,
  type PromptEditorHandle,
} from "../agent-session/react/proseMirrorPromptEditor";
import {
  loadGuiModeContext,
  readGuiModeBootstrap,
  cancelGuiModeSubmit,
  makeGuiModeRequestId,
  submitGuiModePrompt,
  type GuiModeContext,
  type GuiModeProvider,
} from "./bridge";

const h = React.createElement;

type LoadState =
  | { status: "loading" }
  | { status: "ready"; context: GuiModeContext }
  | { status: "error"; message: string };

export function GuiModeApp() {
  const bootstrap = readGuiModeBootstrap();
  const [loadState, setLoadState] = useState<LoadState>(() => bootstrap
    ? { status: "ready", context: bootstrap.context }
    : { status: "loading" });
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
      .catch(() => {
        setLoadState({ status: "error", message: readGuiModeBootstrap()?.errorMessage ?? "" });
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
    "data-gui-mode-page": loadState.status,
    "aria-busy": loadState.status === "loading",
  },
    h("div", { className: "gui-mode-status", role: loadState.status === "error" ? "alert" : "status" },
      loadState.status === "error"
        ? loadState.message
        : h("progress", { "aria-label": bootstrap?.loadingMessage })),
  );
}

function GuiModeHomePage({ context }: { context: GuiModeContext }) {
  const [prompt, setPrompt] = useState("");
  const [selectedProviderId, setSelectedProviderId] = useState(context.selectedProviderId);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState("");
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const activeRequestId = useRef<string | null>(null);
  const cancelledRequestIds = useRef(new Set<string>());
  const blockedRequestIds = useRef(new Set<string>());
  const settledRequestIds = useRef(new Set<string>());
  const selectedProvider = providerForId(context.providers, selectedProviderId);
  const trimmedPrompt = prompt.trim();
  const canSubmit = trimmedPrompt.length > 0 && !isSubmitting;
  const submit = useCallback(() => {
    if (!canSubmit) return;
    setIsSubmitting(true);
    setError("");
    const requestId = makeGuiModeRequestId();
    activeRequestId.current = requestId;
    void submitGuiModePrompt(trimmedPrompt, selectedProvider.id, requestId)
      .catch(async () => {
        if (!cancelledRequestIds.current.has(requestId)) setError(context.copy.errorMessage);
        try {
          await cancelGuiModeSubmit(requestId);
        } catch {
          // Keep duplicate workspace creation blocked until native cancellation is confirmed.
          blockedRequestIds.current.add(requestId);
          setError(context.copy.cancellationUnconfirmed);
        }
      })
      .finally(() => {
        settledRequestIds.current.add(requestId);
        if (blockedRequestIds.current.has(requestId)) return;
        cancelledRequestIds.current.delete(requestId);
        if (activeRequestId.current === requestId) {
          activeRequestId.current = null;
          setIsSubmitting(false);
        }
      });
  }, [canSubmit, context.copy, selectedProvider.id, trimmedPrompt]);
  const cancel = useCallback(() => {
    const requestId = activeRequestId.current;
    if (!requestId) return;
    cancelledRequestIds.current.add(requestId);
    void cancelGuiModeSubmit(requestId).then(() => {
      blockedRequestIds.current.delete(requestId);
      if (settledRequestIds.current.has(requestId) && activeRequestId.current === requestId) {
        cancelledRequestIds.current.delete(requestId);
        activeRequestId.current = null;
        setIsSubmitting(false);
        setError("");
      }
    }).catch(() => setError(context.copy.cancellationUnconfirmed));
  }, [context.copy.cancellationUnconfirmed]);

  return h("section", {
    className: "agent-shell gui-mode-home",
    "aria-label": context.copy.homeTitle,
    style: providerAccentStyle(selectedProvider),
  },
    h("div", {
      className: "agent-thread gui-mode-thread",
      "data-empty": trimmedPrompt.length === 0 ? "true" : undefined,
      role: "log",
      "aria-live": "polite",
    },
      trimmedPrompt.length > 0 ? h(UserChatTurn, { text: prompt }) : null,
    ),
    h("div", { className: CODEX_COMPOSER_STACK },
      h("div", { className: "relative flex w-full flex-col gap-2" },
        h("form", {
          className: "w-full min-w-0",
          onSubmit: (event: React.FormEvent) => {
            event.preventDefault();
            submit();
          },
        },
          h("div", { className: CODEX_COMPOSER_FRAME },
            h("div", {
              className: `${CODEX_COMPOSER_SURFACE} gui-mode-composer overflow-visible rounded-3xl`,
            },
              h("div", { className: CODEX_COMPOSER_INNER },
                h("div", { className: "composer-footer gui-mode-composer-footer" },
                  h("div", { className: "codex-left-rail" },
                    h("button", {
                      className: `${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full gui-mode-add-context`,
                      type: "button",
                      "aria-label": context.copy.setupCommandLabel,
                      title: context.copy.setupCommandLabel,
                    }, guiModePlusIcon("icon-sm")),
                  ),
                  h("div", { className: "min-w-0 gui-mode-editor-shell" },
                    h(PromptEditor, {
                      ref: editorRef,
                      ariaLabel: context.copy.promptPlaceholder,
                      className: "gui-mode-editor text-base",
                      minHeight: "1.25rem",
                      onSubmit: submit,
                      onTextChange: setPrompt,
                      placeholder: context.copy.promptPlaceholder,
                      singleLine: true,
                      value: prompt,
                    }),
                  ),
                  h("div", { className: "codex-action-cluster gui-mode-action-cluster" },
                    h(ProviderSelect, {
                      label: context.copy.providerLabel,
                      providers: context.providers,
                      selectedProviderId: selectedProvider.id,
                      noResultsLabel: context.copy.noProvidersFound,
                      searchPlaceholder: context.copy.providerSearchPlaceholder,
                      onSelectProvider: setSelectedProviderId,
                    }),
                    isSubmitting
                      ? h("button", {
                        className: `${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full gui-mode-cancel`,
                        onClick: cancel,
                        type: "button",
                        "aria-label": context.copy.cancel,
                        title: context.copy.cancel,
                      }, guiModeStopIcon())
                      : null,
                    h("button", {
                      className: `${CODEX_SUBMIT_BUTTON} gui-mode-submit${canSubmit ? "" : " cursor-default opacity-50"}`,
                      "aria-label": isSubmitting ? context.copy.submitting : context.copy.submit,
                      disabled: !canSubmit,
                      type: "submit",
                    }, guiModeSendIcon("icon-sm text-token-dropdown-background")),
                  ),
                ),
                h("div", { className: "gui-mode-error", role: "alert" }, error),
              ),
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
    className: "agent-shell gui-mode-task",
    style: providerAccentStyle(provider),
  },
    h("div", { className: "agent-thread gui-mode-task-thread", role: "log" },
      h("div", { className: "gui-mode-task-heading" },
        h("div", { className: "gui-mode-title" }, context.copy.taskTitle),
        h("div", { className: "gui-mode-runtime-pill" }, provider.displayName),
      ),
      h(UserChatTurn, { label: context.copy.taskPromptLabel, text: context.prompt }),
      h(AssistantChatTurn, {
        provider,
        text: provider.detail,
        commandLabel: context.copy.taskCommandLabel,
        command: provider.taskCommandPreview,
        capabilities: provider.capabilities,
      }),
    ),
  );
}

function ProviderSelect({
  label,
  onSelectProvider,
  providers,
  selectedProviderId,
  noResultsLabel,
  searchPlaceholder,
}: {
  label: string;
  onSelectProvider: (providerId: string) => void;
  providers: GuiModeProvider[];
  selectedProviderId: string;
  noResultsLabel: string;
  searchPlaceholder: string;
}) {
  const [query, setQuery] = useState("");
  const [isOpen, setIsOpen] = useState(false);
  const selectedProvider = providerForId(providers, selectedProviderId);
  const filteredProviders = filterGuiModeProviders(providers, query);
  const selectProviders = filteredProviders.length === 0
    ? [selectedProvider]
    : filteredProviders.some((provider) => provider.id === selectedProvider.id)
    ? filteredProviders
    : [selectedProvider, ...filteredProviders];
  return h("div", {
    className: "model-picker-root gui-mode-provider-picker",
    style: providerAccentStyle(selectedProvider),
  },
    h("button", {
      className: `${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} model-picker rounded-full gui-mode-provider-button`,
      type: "button",
      "aria-expanded": isOpen,
      "aria-haspopup": "menu",
      "aria-label": label,
      onClick: () => setIsOpen((open) => !open),
    },
      h("span", { className: "model-icon gui-mode-provider-icon", "aria-hidden": true }, selectedProvider.displayName.slice(0, 1)),
      h("span", { className: "model-picker-content flex min-w-0 items-center gap-1.5" },
        h("span", { className: "model-label truncate whitespace-nowrap" }, selectedProvider.displayName),
      ),
      h("span", { className: "model-chevron composer-footer__secondary-chevron icon-2xs", "aria-hidden": true }, guiModeChevronIcon()),
    ),
    h("select", {
      "aria-label": label,
      "aria-hidden": true,
      className: "gui-mode-agent-select",
      onChange: (event: React.ChangeEvent<HTMLSelectElement>) => onSelectProvider(event.currentTarget.value),
      tabIndex: -1,
      value: selectedProvider.id,
    },
      selectProviders.map((provider) => h("option", {
        key: provider.id,
        value: provider.id,
      }, provider.displayName)),
    ),
    isOpen
      ? h("div", { className: "provider-dropdown gui-mode-provider-dropdown", role: "menu" },
        h("div", { className: "provider-dropdown-title" }, label),
        h("input", {
          "aria-label": searchPlaceholder,
          autoFocus: true,
          className: "gui-mode-agent-search",
          onChange: (event: React.ChangeEvent<HTMLInputElement>) => setQuery(event.currentTarget.value),
          placeholder: searchPlaceholder,
          type: "search",
          value: query,
        }),
        filteredProviders.length === 0
          ? h("div", { className: "gui-mode-provider-no-results", role: "status" }, noResultsLabel)
          : filteredProviders.map((provider) => h("button", {
            className: "provider-dropdown-item gui-mode-provider-option",
            key: provider.id,
            onClick: () => {
              onSelectProvider(provider.id);
              setIsOpen(false);
              setQuery("");
            },
            role: "menuitem",
            type: "button",
          },
            h("span", { className: "model-icon", "aria-hidden": true }, provider.displayName.slice(0, 1)),
            h("span", { className: "truncate" }, provider.displayName),
            provider.id === selectedProvider.id ? h("span", { className: "gui-mode-provider-check", "aria-hidden": true }, "✓") : null,
          )),
      )
      : null,
  );
}

function guiModeSendIcon(className = "icon-sm") {
  return h("svg", { className, width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M9.33467 16.6663V4.93978L4.6374 9.63704L3.69599 8.69661L9.52998 2.86263C9.78968 2.60314 10.2107 2.60314 10.4704 2.86263L16.3034 8.69661L15.363 9.63704L10.6647 4.9388V16.6663C10.6647 17.0336 10.367 17.3314 9.99971 17.3314C9.63259 17.3312 9.33467 17.0335 9.33467 16.6663Z",
      fill: "currentColor",
    }),
  );
}

function guiModePlusIcon(className = "icon-sm") {
  return h("svg", { className, width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M9.33496 16.5V10.665H3.5C3.13273 10.665 2.83496 10.3673 2.83496 10C2.83496 9.63273 3.13273 9.33496 3.5 9.33496H9.33496V3.5C9.33496 3.13273 9.63273 2.83496 10 2.83496C10.3673 2.83496 10.665 3.13273 10.665 3.5V9.33496H16.5V10.665H10.665V16.5C10.665 16.8673 10.367 17.165 10 17.165C9.63273 17.165 9.33496 16.8673 9.33496 16.5Z",
      fill: "currentColor",
    }),
  );
}

function guiModeStopIcon() {
  return h("svg", { width: "16", height: "16", viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
    h("rect", { x: "4.75", y: "4.75", width: "6.5", height: "6.5", rx: "1", fill: "currentColor" }),
  );
}

function guiModeChevronIcon() {
  return h("svg", { className: "icon-2xs", width: "20", height: "21", viewBox: "0 0 20 21", fill: "none", "aria-hidden": true },
    h("path", { d: "M4.4 7.7L10 13.3L15.6 7.7", fill: "none", stroke: "currentColor", strokeWidth: "1.4", strokeLinecap: "round", strokeLinejoin: "round" }),
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
  return h("div", { className: "codex-assistant-turn gui-mode-chat-turn gui-mode-chat-turn-assistant" },
    h("div", { className: "gui-mode-chat-avatar", style: providerAccentStyle(provider), "aria-hidden": "true" },
      h("span", { className: "gui-mode-provider-mark" }),
    ),
    h("div", { className: "codex-assistant-message gui-mode-chat-message gui-mode-assistant-message" },
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
  return h("div", { className: "codex-user-turn gui-mode-chat-turn gui-mode-chat-turn-user" },
    h("div", { className: "codex-user-bubble gui-mode-chat-message gui-mode-user-message" },
      label ? h("div", { className: "gui-mode-chat-user-label" }, label) : null,
      h("div", { className: "codex-user-message-content gui-mode-chat-message-text" }, text),
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
