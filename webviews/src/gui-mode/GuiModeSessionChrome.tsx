import React from "react";
import { createPortal } from "react-dom";
import type { GuiModeSessionContext, ProviderId } from "../agent-session/shared/types";
import {
  CODEX_BUTTON_BASE,
  CODEX_BUTTON_COMPOSER,
  CODEX_BUTTON_GHOST,
} from "../agent-session/shared/codexClassNames";

const h = React.createElement;

export function GuiModeWelcome({ context }: { context: GuiModeSessionContext }) {
  if (context.page === "task-worktree-pr" && context.prompt?.trim()) {
    return h("div", { className: "gui-mode-task-prompt gui-mode-task-welcome-prompt" },
      h("div", { className: "gui-mode-task-prompt-label" }, context.copy?.taskPromptLabel ?? "Prompt"),
      h("div", { className: "gui-mode-task-prompt-text" }, context.prompt.trim()),
    );
  }
  const folderName = context.workingDirectory?.split("/").filter(Boolean).at(-1) ?? "cmux";
  const title = (context.copy?.emptyTitle ?? "What should we build in cmux?")
    .replace(/\bcmux\b/i, folderName);
  return h("div", { className: "gui-mode-welcome" },
    h("h1", { className: "gui-mode-welcome-title" }, title),
    h("p", { className: "gui-mode-welcome-subtitle" },
      context.copy?.emptySubtitle ?? "Describe an idea, fix a bug, or start with a command.",
    ),

  );
}

export function GuiModeModeToggle({
  mode,
  onChange,
  context,
}: {
  mode: "chat" | "terminal";
  onChange: (mode: "chat" | "terminal") => void;
  context: GuiModeSessionContext;
}) {
  return h("div", {
    "aria-label": context.copy?.modeLabel ?? "Composer mode",
    className: "gui-mode-agent-mode-toggle",
    role: "tablist",
  },
    h("button", {
      "aria-selected": mode === "chat",
      className: `gui-mode-agent-mode-button${mode === "chat" ? " is-selected" : ""}`,
      onClick: () => onChange("chat"),
      role: "tab",
      type: "button",
    }, context.copy?.chatMode ?? "Chat"),
    h("button", {
      "aria-selected": mode === "terminal",
      className: `gui-mode-agent-mode-button${mode === "terminal" ? " is-selected" : ""}`,
      onClick: () => onChange("terminal"),
      role: "tab",
      type: "button",
    }, context.copy?.terminalMode ?? "Terminal"),
  );
}

export function GuiModeContextStrip({ context }: { context: GuiModeSessionContext }) {
  const folderName = context.workingDirectory?.split("/").filter(Boolean).at(-1)
    ?? context.copy?.folderFallback
    ?? "Current folder";
  return h("div", {
    "aria-label": context.copy?.modeLabel ?? "Context",
    className: "gui-mode-agent-context-strip",
  },
    h("span", { className: "gui-mode-agent-context-folder", title: context.workingDirectory },
      h("svg", { width: 13, height: 13, viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
        h("path", { d: "M2 4h4l1.5 2H14v7H2V4Z", stroke: "currentColor", strokeWidth: 1.2, strokeLinejoin: "round" }),
      ), folderName),
    h("span", { className: "gui-mode-agent-context-separator", "aria-hidden": true }, "·"),
    h("span", null, context.copy?.localLabel ?? "Local"),
    context.gitBranch
      ? h(React.Fragment, null,
        h("span", { className: "gui-mode-agent-context-separator", "aria-hidden": true }, "·"),
        h("span", { className: "gui-mode-agent-context-branch" }, "⑂", context.gitBranch),
      )
      : null,
  );
}

/** Provider switcher used by the real AgentSession surface in GUI Mode. */
export function GuiModeProviderPicker({
  context,
  disabled = false,
  onChange,
  providers: availableProviders,
  providerId,
}: {
  context: GuiModeSessionContext;
  disabled?: boolean;
  onChange: (providerId: ProviderId) => void;
  providers?: GuiModeSessionContext["providers"];
  providerId: ProviderId;
}) {
  const [isOpen, setIsOpen] = React.useState(false);
  const [query, setQuery] = React.useState("");
  const [highlightedIndex, setHighlightedIndex] = React.useState(0);
  const providers = availableProviders ?? context.providers ?? [];
  const selected = providers.find((provider) => provider.id === providerId) ?? providers[0];
  const normalizedQuery = query.trim().toLocaleLowerCase();
  const filtered = providers.filter((provider) => {
    if (!normalizedQuery) return true;
    return `${provider.id} ${provider.displayName}`.toLocaleLowerCase().includes(normalizedQuery);
  });
  const choose = (nextProviderId: ProviderId) => {
    onChange(nextProviderId);
    setIsOpen(false);
    setQuery("");
    setHighlightedIndex(0);
  };
  const moveHighlight = (direction: 1 | -1) => {
    if (filtered.length === 0) return;
    setHighlightedIndex((index) => (index + direction + filtered.length) % filtered.length);
  };

  if (!selected) return null;
  return h("div", {
    className: "gui-mode-provider-picker",
    onBlur: (event: React.FocusEvent<HTMLDivElement>) => {
      if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
        setIsOpen(false);
        setQuery("");
      }
    },
    style: { "--gui-provider-accent": selected.accentColor ?? "var(--agent-accent)" } as React.CSSProperties,
  },
    h("button", {
      "aria-expanded": isOpen,
      "aria-haspopup": "menu",
      "aria-label": context.copy?.providerLabel ?? "Agent",
      className: `${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} model-picker rounded-full gui-mode-provider-button`,
      disabled,
      onClick: () => {
        if (!disabled) setIsOpen((open) => !open);
      },
      onKeyDown: (event: React.KeyboardEvent<HTMLButtonElement>) => {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          setIsOpen(true);
          moveHighlight(event.key === "ArrowDown" ? 1 : -1);
        }
      },
      type: "button",
    },
      h("span", { className: "model-icon gui-mode-provider-icon", "aria-hidden": true }, selected.displayName.slice(0, 1)),
      h("span", { className: "model-picker-content flex min-w-0 items-center gap-1.5" },
        h("span", { className: "model-label truncate whitespace-nowrap" }, selected.displayName),
      ),
      h("span", { className: "model-chevron composer-footer__secondary-chevron icon-2xs", "aria-hidden": true }, "⌄"),
    ),
    isOpen
      ? h("div", { className: "provider-dropdown gui-mode-provider-dropdown", role: "menu" },
        h("div", { className: "provider-dropdown-title" }, context.copy?.providerLabel ?? "Agent"),
        h("input", {
          "aria-label": context.copy?.providerSearchPlaceholder ?? "Search agents",
          autoFocus: true,
          className: "gui-mode-agent-search",
          onChange: (event: React.ChangeEvent<HTMLInputElement>) => {
            setQuery(event.currentTarget.value);
            setHighlightedIndex(0);
          },
          onKeyDown: (event: React.KeyboardEvent<HTMLInputElement>) => {
            if (event.key === "Escape") {
              event.preventDefault();
              setIsOpen(false);
              setQuery("");
            } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault();
              moveHighlight(event.key === "ArrowDown" ? 1 : -1);
            } else if (event.key === "Enter") {
              event.preventDefault();
              const choice = filtered[highlightedIndex];
              if (choice) choose(choice.id);
            }
          },
          placeholder: context.copy?.providerSearchPlaceholder ?? "Search agents",
          type: "search",
          value: query,
        }),
        filtered.length === 0
          ? h("div", { className: "gui-mode-provider-no-results", role: "status" }, context.copy?.noProvidersFound ?? "No agents found")
          : filtered.map((provider, index) => h("button", {
            "aria-checked": provider.id === providerId,
            className: `provider-dropdown-item gui-mode-provider-option${index === highlightedIndex ? " gui-mode-provider-option-highlighted" : ""}`,
            key: provider.id,
            onClick: () => choose(provider.id),
            role: "menuitemradio",
            type: "button",
          },
            h("span", { className: "model-icon", "aria-hidden": true }, provider.displayName.slice(0, 1)),
            h("span", { className: "truncate" }, provider.displayName),
            provider.id === providerId ? h("span", { className: "gui-mode-provider-check", "aria-hidden": true }, "✓") : null,
          )),
      )
      : null,
  );
}

export function GuiModeModelPicker({
  context,
  providerId,
  disabled = false,
  modelId,
  reasoningEffort,
  onChange,
}: {
  context: GuiModeSessionContext;
  providerId: string;
  disabled?: boolean;
  modelId: string;
  reasoningEffort: string;
  onChange: (modelId: string, reasoningEffort: string) => void;
}) {
  const [isOpen, setIsOpen] = React.useState(false);
  const [menuPosition, setMenuPosition] = React.useState<{ left: number; bottom: number; maxHeight: number } | null>(null);
  const triggerRef = React.useRef<HTMLButtonElement | null>(null);
  const menuRef = React.useRef<HTMLDivElement | null>(null);
  const models = (context.models ?? []).filter((model) => model.providerId === providerId);
  const selectedModel = models.find((model) => model.id === modelId) ?? models[0];
  const efforts = selectedModel?.reasoningEfforts ?? ["default"];
  const effortLabels: Record<string, string> = {
    default: context.copy?.reasoningDefault ?? "Default",
    low: context.copy?.reasoningLow ?? "Low",
    medium: context.copy?.reasoningMedium ?? "Medium",
    high: context.copy?.reasoningHigh ?? "High",
    xhigh: context.copy?.reasoningExtraHigh ?? "Extra high",
  };
  const effortLabel = effortLabels[reasoningEffort] ?? reasoningEffort;
  const openMenu = () => {
    if (disabled) return;
    const rect = triggerRef.current?.getBoundingClientRect();
    if (rect) {
      setMenuPosition({ left: Math.max(8, Math.min(rect.left, window.innerWidth - 276)), bottom: Math.max(8, window.innerHeight - rect.top + 8), maxHeight: Math.max(64, rect.top - 16) });
    }
    setIsOpen(true);
  };
  React.useEffect(() => {
    if (!isOpen) return;
    const outside = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!menuRef.current?.contains(target) && !triggerRef.current?.contains(target)) setIsOpen(false);
    };
    const close = () => setIsOpen(false);
    document.addEventListener("pointerdown", outside);
    window.addEventListener("resize", close);
    return () => {
      document.removeEventListener("pointerdown", outside);
      window.removeEventListener("resize", close);
    };
  }, [isOpen]);
  const menu = isOpen
    ? h("div", {
        className: "gui-mode-agent-model-menu",
        ref: menuRef,
        role: "menu",
        style: menuPosition
          ? { position: "fixed", left: `${menuPosition.left}px`, bottom: `${menuPosition.bottom}px`, maxHeight: `${menuPosition.maxHeight}px`, right: "auto" }
          : undefined,
        onKeyDown: (event: React.KeyboardEvent<HTMLDivElement>) => {
          if (event.key === "Escape") {
            event.preventDefault();
            setIsOpen(false);
            triggerRef.current?.focus();
          }
        },
      },
        h("div", { className: "gui-mode-agent-model-menu-title" }, context.copy?.modelLabel ?? "Model"),
        models.map((model) => h("div", { className: "gui-mode-agent-model-group", key: model.id },
          h("button", {
            "aria-checked": model.id === selectedModel?.id,
            className: `gui-mode-agent-model-option${model.id === selectedModel?.id ? " is-selected" : ""}`,
            onClick: () => {
              const nextEffort = model.reasoningEfforts.includes(reasoningEffort)
                ? reasoningEffort
                : model.defaultReasoningEffort ?? model.reasoningEfforts[0] ?? "default";
              onChange(model.id, nextEffort);
              setIsOpen(false);
              triggerRef.current?.focus();
            },
            role: "menuitemradio",
            type: "button",
          }, model.displayName, model.id === selectedModel?.id ? "✓" : null),
          model.id === selectedModel?.id
            ? h("div", { className: "gui-mode-agent-reasoning-options", "aria-label": context.copy?.reasoningLabel ?? "Reasoning" },
              efforts.map((effort) => h("button", {
                className: effort === reasoningEffort ? "is-selected" : undefined,
                key: effort,
                onClick: () => {
                  onChange(model.id, effort);
                  setIsOpen(false);
                  triggerRef.current?.focus();
                },
                type: "button",
              }, effortLabels[effort] ?? effort)),
            )
            : null,
        )),
      )
    : null;
  return h("div", {
    className: "gui-mode-agent-model-picker",
    onBlur: (event: React.FocusEvent<HTMLDivElement>) => {
      const target = event.relatedTarget as Node | null;
      if (!event.currentTarget.contains(target) && !menuRef.current?.contains(target)) setIsOpen(false);
    },
  },
    h("button", {
      ref: triggerRef,
      "aria-expanded": isOpen,
      "aria-haspopup": "menu",
      "aria-disabled": disabled || undefined,
      "aria-label": `${context.copy?.modelLabel ?? "Model"}: ${selectedModel?.displayName ?? "Default"}, ${effortLabel}`,
      className: "gui-mode-agent-model-trigger",
      disabled,
      onClick: () => (isOpen ? setIsOpen(false) : openMenu()),
      type: "button",
    }, h("span", { "aria-hidden": true }, "✦"), h("span", { className: "gui-mode-agent-model-name" }, selectedModel?.displayName ?? context.copy?.reasoningDefault ?? "Default"), h("span", { className: "gui-mode-agent-model-effort" }, effortLabel), h("span", { "aria-hidden": true }, "⌄")),
    typeof document === "undefined" ? menu : createPortal(menu, document.body),
  );
}
