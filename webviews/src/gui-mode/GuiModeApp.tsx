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
  executeGuiModeTerminal,
  makeGuiModeRequestId,
  isGuiModeBridgeTimeout,
  submitGuiModePrompt,
  type GuiModeContext,
  type GuiModeMode,
  type GuiModeModel,
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

function GuiModeHomePage({ context, taskPrompt }: { context: GuiModeContext; taskPrompt?: string }) {
  const [prompt, setPrompt] = useState("");
  const [workingDirectory, setWorkingDirectory] = useState(context.workingDirectory);
  const [mode, setMode] = useState<GuiModeMode>("chat");
  const [selectedProviderId, setSelectedProviderId] = useState(context.selectedProviderId);
  const [selectedModelId, setSelectedModelId] = useState(
    context.selectedModelId ?? modelsForProvider(context, context.selectedProviderId)[0]?.id ?? "default",
  );
  const [selectedReasoningEffort, setSelectedReasoningEffort] = useState(
    context.selectedReasoningEffort ?? "xhigh",
  );
  const [permissionMode, setPermissionMode] = useState("default");
  const [contextMenuOpen, setContextMenuOpen] = useState(false);
  const [includeCurrentFolder, setIncludeCurrentFolder] = useState(false);
  const terminalRequestId = useRef<string | null>(null);
  const [terminalStatus, setTerminalStatus] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState("");
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const activeRequestId = useRef<string | null>(null);
  const cancelledRequestIds = useRef(new Set<string>());
  const confirmedCancellationRequestIds = useRef(new Set<string>());
  const blockedRequestIds = useRef(new Set<string>());
  const settledRequestIds = useRef(new Set<string>());
  const selectedProvider = providerForId(context.providers, selectedProviderId);
  const modelOptions = modelsForProvider(context, selectedProvider.id);
  const selectedModel = modelOptions.find((model) => model.id === selectedModelId) ?? modelOptions[0];
  const reasoningOptions = selectedModel?.reasoningEfforts ?? ["default"];
  const reasoningEffort = reasoningOptions.includes(selectedReasoningEffort)
    ? selectedReasoningEffort
    : reasoningOptions.includes("xhigh") ? "xhigh" : reasoningOptions[0] ?? "default";
  const trimmedPrompt = prompt.trim();
  const visibleTaskPrompt = taskPrompt?.trim() ?? "";
  const currentFolderName = workingDirectory?.split("/").filter(Boolean).at(-1)
    ?? context.copy.folderFallback
    ?? "cmux";
  const emptyTitle = (context.copy.emptyTitle ?? "What should we build in cmux?")
    .replace(/\bcmux\b/i, currentFolderName);
  const canSubmit = trimmedPrompt.length > 0 && !isSubmitting;
  const submit = useCallback(() => {
    if (!canSubmit) return;
    setIsSubmitting(true);
    setError("");
    setTerminalStatus("");
    if (mode === "terminal") {
      const requestId = terminalRequestId.current ?? makeGuiModeRequestId();
      terminalRequestId.current = requestId;
      void executeGuiModeTerminal(trimmedPrompt, requestId)
        .then((result) => {
          terminalRequestId.current = null;
          setWorkingDirectory(result.workingDirectory);
          if (result.exitCode === 0) setPrompt("");
          setTerminalStatus(result.output);
        })
        .catch(() => setError(context.copy.terminalErrorMessage ?? context.copy.errorMessage))
        .finally(() => setIsSubmitting(false));
      return;
    }
    const requestId = makeGuiModeRequestId();
    activeRequestId.current = requestId;
    const promptWithContext = includeCurrentFolder && workingDirectory
      ? `In ${workingDirectory}: ${trimmedPrompt}`
      : trimmedPrompt;
    void submitGuiModePrompt(promptWithContext, selectedProvider.id, requestId, {
      modelId: selectedModel?.id,
      permissionMode,
      reasoningEffort,
    })
      .catch(async (error) => {
        if (confirmedCancellationRequestIds.current.has(requestId)) return;
        if (!isGuiModeBridgeTimeout(error)) {
          setError(context.copy.errorMessage);
          return;
        }
        if (!cancelledRequestIds.current.has(requestId)) setError(context.copy.errorMessage);
        try {
          await cancelGuiModeSubmit(requestId);
          confirmedCancellationRequestIds.current.add(requestId);
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
        confirmedCancellationRequestIds.current.delete(requestId);
        if (activeRequestId.current === requestId) {
          activeRequestId.current = null;
          setIsSubmitting(false);
        }
      });
  }, [canSubmit, context.copy, workingDirectory, includeCurrentFolder, mode, permissionMode, reasoningEffort, selectedModel?.id, selectedProvider.id, trimmedPrompt]);
  const cancel = useCallback(() => {
    const requestId = activeRequestId.current;
    if (!requestId) return;
    cancelledRequestIds.current.add(requestId);
    void cancelGuiModeSubmit(requestId).then(() => {
      confirmedCancellationRequestIds.current.add(requestId);
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
    className: `agent-shell gui-mode-home${visibleTaskPrompt.length > 0 ? " gui-mode-task" : ""}`,
    "aria-label": context.copy.homeTitle,
    style: providerAccentStyle(selectedProvider),
  },
    h("div", {
      className: "agent-thread gui-mode-thread",
      "data-empty": visibleTaskPrompt.length === 0 && trimmedPrompt.length === 0 ? "true" : undefined,
      role: "log",
      "aria-live": "polite",
    },
      visibleTaskPrompt.length > 0
        ? h("div", { className: "gui-mode-task-prompt" },
          h("div", { className: "gui-mode-task-prompt-label" }, context.copy.taskPromptLabel),
          h("div", { className: "gui-mode-task-prompt-text" }, visibleTaskPrompt),
        )
        : visibleTaskPrompt.length === 0 && trimmedPrompt.length === 0
        ? h("div", { className: "gui-mode-empty-state" },
          h("h1", { className: "gui-mode-empty-title" }, emptyTitle),
          h("p", { className: "gui-mode-empty-subtitle" }, context.copy.emptySubtitle ?? "Describe an idea, fix a bug, or start with a command."),
          h("div", { className: "gui-mode-voice-card" },
            h("div", { className: "gui-mode-voice-icon", "aria-hidden": true }, guiModeMicIcon()),
            h("div", { className: "gui-mode-voice-copy" },
              h("strong", null, context.copy.voiceTitle ?? "Talk to Codex"),
              h("span", null, context.copy.voiceDescription ?? "Use your voice to work hands-free."),
            ),
            h("button", {
              className: "gui-mode-voice-action",
              disabled: true,
              type: "button",
            }, context.copy.voiceAction ?? "Try voice"),
          ),
        )
        : trimmedPrompt.length > 0 ? h(UserChatTurn, { text: prompt }) : null,
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
                h(ModeToggle, {
                  mode,
                  chatLabel: context.copy.chatMode ?? "Chat",
                  terminalLabel: context.copy.terminalMode ?? "Terminal",
                  modeLabel: context.copy.modeLabel ?? "Composer mode",
                  onChange: (nextMode: GuiModeMode) => {
                    if (!isSubmitting) {
                      setMode(nextMode);
                      setTerminalStatus("");
                      setError("");
                    }
                  },
                }),
                h("div", { className: "composer-footer gui-mode-composer-footer" },
                  h("div", { className: "gui-mode-editor-row" },
                    h(ContextButton, {
                      context,
                      includeCurrentFolder,
                      isOpen: contextMenuOpen,
                      onOpenChange: setContextMenuOpen,
                      onToggleFolder: () => {
                        setIncludeCurrentFolder((value) => !value);
                        setContextMenuOpen(false);
                        editorRef.current?.focus();
                      },
                    }),
                    h("div", { className: "min-w-0 gui-mode-editor-shell" },
                    h(PromptEditor, {
                      ref: editorRef,
                      ariaLabel: mode === "terminal"
                        ? context.copy.terminalPlaceholder ?? "Run a terminal command"
                        : context.copy.promptPlaceholder,
                      className: "gui-mode-editor text-base",
                      minHeight: "1.25rem",
                      onSubmit: submit,
                      onTextChange: setPrompt,
                      placeholder: mode === "terminal"
                        ? context.copy.terminalPlaceholder ?? "Run a terminal command"
                        : context.copy.promptPlaceholder,
                      singleLine: true,
                      value: prompt,
                    }),
                    ),
                  ),
                  h("div", { className: "codex-action-cluster gui-mode-action-cluster" },
                    h(ProviderSelect, {
                      label: context.copy.providerLabel,
                      providers: context.providers,
                      selectedProviderId: selectedProvider.id,
                      noResultsLabel: context.copy.noProvidersFound,
                      searchPlaceholder: context.copy.providerSearchPlaceholder,
                      onSelectProvider: (providerId: string) => {
                        setSelectedProviderId(providerId);
                        const nextModel = modelsForProvider(context, providerId)[0];
                        setSelectedModelId(nextModel?.id ?? "default");
                        setSelectedReasoningEffort(nextModel?.reasoningEfforts.includes("xhigh") ? "xhigh" : nextModel?.reasoningEfforts[0] ?? "default");
                      },
                    }),
                    h(ModelSelect, {
                      label: context.copy.modelLabel ?? "Model",
                      models: modelOptions,
                      reasoningLabel: context.copy.reasoningLabel ?? "Reasoning",
                      reasoningEffort,
                      reasoningLabels: {
                        low: context.copy.reasoningLow ?? "Low",
                        medium: context.copy.reasoningMedium ?? "Medium",
                        high: context.copy.reasoningHigh ?? "High",
                        xhigh: context.copy.reasoningExtraHigh ?? "Extra high",
                        default: context.copy.reasoningDefault ?? "Default",
                      },
                      selectedModelId: selectedModel?.id ?? "default",
                      onSelectModel: (nextModelId: string, nextReasoningEffort: string) => {
                        setSelectedModelId(nextModelId);
                        setSelectedReasoningEffort(nextReasoningEffort);
                      },
                    }),
                    h(PermissionSelect, {
                      label: context.copy.permissionLabel ?? "Ask for approval",
                      mode: permissionMode,
                      labels: {
                        default: context.copy.permissionDefault ?? "Ask for approval",
                        "full-access": context.copy.permissionFullAccess ?? "Full access",
                        "auto-review": context.copy.permissionAutoReview ?? "Auto-review",
                        custom: context.copy.permissionCustom ?? "Custom",
                      },
                      onChange: setPermissionMode,
                    }),
                    isSubmitting && mode !== "terminal"
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
                terminalStatus
                  ? h("div", { className: "gui-mode-terminal-status", role: "status" }, terminalStatus)
                  : null,
                h("div", { className: "gui-mode-error", role: "alert" }, error),
              ),
            ),
          ),
        ),
        h("div", { className: "gui-mode-context-strip", "aria-label": context.copy.contextLabel ?? "Context" },
          h("span", { className: "gui-mode-context-folder" }, guiModeFolderIcon(), workingDirectory?.split("/").filter(Boolean).at(-1) ?? context.copy.folderFallback ?? "Current folder"),
          h("span", { className: "gui-mode-context-divider", "aria-hidden": true }, "·"),
          h("span", null, context.copy.localLabel ?? "Local"),
          context.gitBranch
            ? h(React.Fragment, null,
              h("span", { className: "gui-mode-context-divider", "aria-hidden": true }, "·"),
              h("span", { className: "gui-mode-context-branch" }, guiModeBranchIcon(), context.gitBranch),
            )
            : null,
        ),
      ),
    ),
  );
}

function GuiModeTaskPage({ context }: { context: GuiModeContext }) {
  return h(GuiModeHomePage, {
    context: {
      ...context,
      page: "home",
    },
    taskPrompt: context.prompt,
  });
}

function ModeToggle({
  mode,
  chatLabel,
  terminalLabel,
  modeLabel,
  onChange,
}: {
  mode: GuiModeMode;
  chatLabel: string;
  terminalLabel: string;
  modeLabel: string;
  onChange: (mode: GuiModeMode) => void;
}) {
  return h("div", { className: "gui-mode-mode-toggle", role: "tablist", "aria-label": modeLabel },
    h("button", {
      className: `gui-mode-mode-button${mode === "chat" ? " is-selected" : ""}`,
      "aria-selected": mode === "chat",
      onClick: () => onChange("chat"),
      role: "tab",
      type: "button",
    }, chatLabel),
    h("button", {
      className: `gui-mode-mode-button${mode === "terminal" ? " is-selected" : ""}`,
      "aria-selected": mode === "terminal",
      onClick: () => onChange("terminal"),
      role: "tab",
      type: "button",
    }, terminalLabel),
  );
}

function ContextButton({
  context,
  includeCurrentFolder,
  isOpen,
  onOpenChange,
  onToggleFolder,
}: {
  context: GuiModeContext;
  includeCurrentFolder: boolean;
  isOpen: boolean;
  onOpenChange: (isOpen: boolean) => void;
  onToggleFolder: () => void;
}) {
  return h("div", { className: "gui-mode-context-picker" },
    h("button", {
      className: `${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full gui-mode-context-button${includeCurrentFolder ? " is-selected" : ""}`,
      "aria-expanded": isOpen,
      "aria-haspopup": "menu",
      "aria-label": context.copy.contextLabel ?? "Add context",
      onClick: () => onOpenChange(!isOpen),
      type: "button",
    }, guiModePlusIcon()),
    isOpen
      ? h("div", { className: "gui-mode-context-menu", role: "menu" },
        h("button", {
          className: "gui-mode-context-menu-item",
          "aria-checked": includeCurrentFolder,
          onClick: onToggleFolder,
          role: "menuitemcheckbox",
          type: "button",
        }, guiModeFolderIcon(), context.copy.currentFolder ?? "Current folder", includeCurrentFolder ? "✓" : null),
      )
      : null,
  );
}

function ModelSelect({
  label,
  models,
  reasoningLabel,
  reasoningEffort,
  reasoningLabels,
  selectedModelId,
  onSelectModel,
}: {
  label: string;
  models: GuiModeModel[];
  reasoningLabel: string;
  reasoningEffort: string;
  reasoningLabels: Record<string, string>;
  selectedModelId: string;
  onSelectModel: (modelId: string, reasoningEffort: string) => void;
}) {
  const [isOpen, setIsOpen] = useState(false);
  const selectedModel = models.find((model) => model.id === selectedModelId) ?? models[0];
  const displayReasoning = reasoningLabels[reasoningEffort] ?? reasoningEffort;
  return h("div", { className: "gui-mode-model-picker" },
    h("button", {
      className: `${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} rounded-full gui-mode-model-button`,
      "aria-expanded": isOpen,
      "aria-haspopup": "menu",
      "aria-label": `${label}: ${selectedModel?.displayName ?? "Default"}, ${displayReasoning}`,
      onClick: () => setIsOpen((open) => !open),
      type: "button",
    },
      h("span", { className: "gui-mode-model-sparkle", "aria-hidden": true }, "✦"),
      h("span", { className: "gui-mode-model-label" }, selectedModel?.displayName ?? "Default"),
      h("span", { className: "gui-mode-reasoning-label" }, displayReasoning),
      guiModeChevronIcon(),
    ),
    isOpen
      ? h("div", { className: "gui-mode-model-menu", role: "menu" },
        h("div", { className: "gui-mode-model-menu-title" }, label),
        models.map((model) => h("div", { className: "gui-mode-model-group", key: model.id },
          h("button", {
            className: `gui-mode-model-option${model.id === selectedModel?.id ? " is-selected" : ""}`,
            onClick: () => {
              const nextReasoning = model.reasoningEfforts.includes(reasoningEffort)
                ? reasoningEffort
                : model.reasoningEfforts.includes("xhigh") ? "xhigh" : model.reasoningEfforts[0] ?? "default";
              onSelectModel(model.id, nextReasoning);
              setIsOpen(false);
            },
            role: "menuitemradio",
            "aria-checked": model.id === selectedModel?.id,
            type: "button",
          }, model.displayName, model.id === selectedModel?.id ? "✓" : null),
          model.id === selectedModel?.id
            ? h("div", { className: "gui-mode-reasoning-group", "aria-label": reasoningLabel },
              model.reasoningEfforts.map((effort) => h("button", {
                className: `gui-mode-reasoning-option${effort === reasoningEffort ? " is-selected" : ""}`,
                key: effort,
                onClick: () => {
                  onSelectModel(model.id, effort);
                  setIsOpen(false);
                },
                type: "button",
              }, reasoningLabels[effort] ?? effort)),
            )
            : null,
        )),
      )
      : null,
  );
}

function PermissionSelect({
  label,
  mode,
  labels,
  onChange,
}: {
  label: string;
  mode: string;
  labels: Record<string, string>;
  onChange: (mode: string) => void;
}) {
  const [isOpen, setIsOpen] = useState(false);
  const options = ["default", "full-access", "auto-review", "custom"];
  return h("div", { className: "gui-mode-permission-picker" },
    h("button", {
      className: `${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} rounded-full gui-mode-permission-button`,
      "aria-expanded": isOpen,
      "aria-haspopup": "menu",
      "aria-label": label,
      onClick: () => setIsOpen((open) => !open),
      type: "button",
    }, labels[mode] ?? labels.default ?? label, guiModeChevronIcon()),
    isOpen
      ? h("div", { className: "gui-mode-permission-menu", role: "menu" },
        options.map((option) => h("button", {
          className: `gui-mode-permission-option${option === mode ? " is-selected" : ""}`,
          "aria-checked": option === mode,
          onClick: () => {
            onChange(option);
            setIsOpen(false);
          },
          role: "menuitemradio",
          type: "button",
        }, labels[option] ?? option, option === mode ? "✓" : null)),
      )
      : null,
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
  const [highlightedIndex, setHighlightedIndex] = useState(0);
  const selectedProvider = providerForId(providers, selectedProviderId);
  const filteredProviders = filterGuiModeProviders(providers, query);
  const selectProviders = filteredProviders.length === 0
    ? [selectedProvider]
    : filteredProviders.some((provider) => provider.id === selectedProvider.id)
    ? filteredProviders
    : [selectedProvider, ...filteredProviders];
  const chooseProvider = (provider: GuiModeProvider) => {
    onSelectProvider(provider.id);
    setIsOpen(false);
    setQuery("");
    setHighlightedIndex(0);
  };
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
      onKeyDown: (event: React.KeyboardEvent<HTMLButtonElement>) => {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          setIsOpen(true);
          setHighlightedIndex((index) => {
            const next = event.key === "ArrowDown" ? index + 1 : index - 1;
            return (next + selectProviders.length) % selectProviders.length;
          });
        }
      },
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
          onKeyDown: (event: React.KeyboardEvent<HTMLInputElement>) => {
            if (event.key === "Escape") {
              event.preventDefault();
              setIsOpen(false);
              setQuery("");
              setHighlightedIndex(0);
            } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault();
              setHighlightedIndex((index) => {
                const next = event.key === "ArrowDown" ? index + 1 : index - 1;
                return filteredProviders.length === 0 ? 0 : (next + filteredProviders.length) % filteredProviders.length;
              });
            } else if (event.key === "Enter") {
              event.preventDefault();
              const provider = filteredProviders[highlightedIndex];
              if (provider) chooseProvider(provider);
            }
          },
          type: "search",
          value: query,
        }),
        filteredProviders.length === 0
          ? h("div", { className: "gui-mode-provider-no-results", role: "status" }, noResultsLabel)
          : filteredProviders.map((provider, index) => h("button", {
            "aria-selected": index === highlightedIndex,
            className: `provider-dropdown-item gui-mode-provider-option${index === highlightedIndex ? " gui-mode-provider-option-highlighted" : ""}`,
            key: provider.id,
            onClick: () => chooseProvider(provider),
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

function UserChatTurn({ label, text }: { label?: string; text: string }) {
  return h("div", { className: "codex-user-turn gui-mode-chat-turn gui-mode-chat-turn-user" },
    h("div", { className: "codex-user-bubble gui-mode-chat-message gui-mode-user-message" },
      label ? h("div", { className: "gui-mode-chat-user-label" }, label) : null,
      h("div", { className: "codex-user-message-content gui-mode-chat-message-text" }, text),
    ),
  );
}

function modelsForProvider(context: GuiModeContext, providerId: string): GuiModeModel[] {
  const models = context.models?.filter((model) => model.providerId === providerId) ?? [];
  if (models.length > 0) return models;
  if (providerId === "codex") {
    return [
      { id: "gpt-6-astra", displayName: "GPT-6 Astra", providerId, reasoningEfforts: ["low", "medium", "high", "xhigh"] },
      { id: "gpt-5.5", displayName: "GPT-5.5", providerId, reasoningEfforts: ["low", "medium", "high"] },
    ];
  }
  return [{ id: "default", displayName: "Default", providerId, reasoningEfforts: ["default"] }];
}

function guiModePlusIcon() {
  return h("svg", { width: "16", height: "16", viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
    h("path", { d: "M8 3v10M3 8h10", stroke: "currentColor", strokeWidth: "1.5", strokeLinecap: "round" }),
  );
}

function guiModeFolderIcon() {
  return h("svg", { width: "14", height: "14", viewBox: "0 0 14 14", fill: "none", "aria-hidden": true },
    h("path", { d: "M1.5 3.5h4l1.2 1.3h5.8v6.2H1.5V3.5Z", stroke: "currentColor", strokeWidth: "1.1", strokeLinejoin: "round" }),
  );
}

function guiModeBranchIcon() {
  return h("svg", { width: "13", height: "13", viewBox: "0 0 13 13", fill: "none", "aria-hidden": true },
    h("path", { d: "M3.25 2.25v5.5a2 2 0 0 0 2 2h4.5M9.75 9.75l-1.5-1.5m1.5 1.5-1.5 1.5M3.25 2.25a1 1 0 1 0 0-2 1 1 0 0 0 0 2ZM9.75 11.75a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z", stroke: "currentColor", strokeWidth: "1", strokeLinecap: "round", strokeLinejoin: "round" }),
  );
}

function guiModeMicIcon() {
  return h("svg", { width: "18", height: "18", viewBox: "0 0 18 18", fill: "none", "aria-hidden": true },
    h("rect", { x: "6", y: "2", width: "6", height: "9", rx: "3", stroke: "currentColor", strokeWidth: "1.3" }),
    h("path", { d: "M3.5 8.5a5.5 5.5 0 0 0 11 0M9 14v2M6.5 16h5", stroke: "currentColor", strokeWidth: "1.3", strokeLinecap: "round" }),
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
