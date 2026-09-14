import React from "react";
import type { GuiModeSessionContext } from "../agent-session/shared/types";

const h = React.createElement;

export function GuiModeWelcome({ context }: { context: GuiModeSessionContext }) {
  const folderName = context.workingDirectory?.split("/").filter(Boolean).at(-1) ?? "cmux";
  const title = (context.copy?.emptyTitle ?? "What should we build in cmux?")
    .replace(/\bcmux\b/i, folderName);
  return h("div", { className: "gui-mode-welcome" },
    h("h1", { className: "gui-mode-welcome-title" }, title),
    h("p", { className: "gui-mode-welcome-subtitle" },
      context.copy?.emptySubtitle ?? "Describe an idea, fix a bug, or start with a command.",
    ),
    h("div", { className: "gui-mode-welcome-voice" },
      h("span", { className: "gui-mode-welcome-voice-icon", "aria-hidden": true }, "◉"),
      h("span", { className: "gui-mode-welcome-voice-copy" },
        h("strong", null, context.copy?.voiceTitle ?? "Talk to Codex"),
        h("small", null, context.copy?.voiceDescription ?? "Use your voice to work hands-free."),
      ),
      h("button", { disabled: true, type: "button" }, context.copy?.voiceAction ?? "Try voice"),
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
    h("span", { className: "gui-mode-agent-context-folder" }, "▱", folderName),
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

export function GuiModeModelPicker({
  context,
  providerId,
  modelId,
  reasoningEffort,
  onChange,
}: {
  context: GuiModeSessionContext;
  providerId: string;
  modelId: string;
  reasoningEffort: string;
  onChange: (modelId: string, reasoningEffort: string) => void;
}) {
  const [isOpen, setIsOpen] = React.useState(false);
  const models = (context.models ?? []).filter((model) => model.providerId === providerId);
  const selectedModel = models.find((model) => model.id === modelId) ?? models[0];
  const efforts = selectedModel?.reasoningEfforts ?? ["default"];
  const effortLabel = reasoningEffort === "extra-high" ? "Extra high" : reasoningEffort;
  return h("div", { className: "gui-mode-agent-model-picker" },
    h("button", {
      "aria-expanded": isOpen,
      "aria-haspopup": "menu",
      "aria-label": `${context.copy?.modelLabel ?? "Model"}: ${selectedModel?.displayName ?? "Default"}, ${effortLabel}`,
      className: "gui-mode-agent-model-trigger",
      onClick: () => setIsOpen((open) => !open),
      type: "button",
    }, "✦", selectedModel?.displayName ?? "Default", h("span", { className: "gui-mode-agent-model-effort" }, effortLabel), "⌄"),
    isOpen
      ? h("div", { className: "gui-mode-agent-model-menu", role: "menu" },
        h("div", { className: "gui-mode-agent-model-menu-title" }, context.copy?.modelLabel ?? "Model"),
        models.map((model) => h("div", { className: "gui-mode-agent-model-group", key: model.id },
          h("button", {
            "aria-checked": model.id === selectedModel?.id,
            className: `gui-mode-agent-model-option${model.id === selectedModel?.id ? " is-selected" : ""}`,
            onClick: () => {
              const nextEffort = efforts.includes(reasoningEffort) ? reasoningEffort : model.reasoningEfforts[0] ?? "default";
              onChange(model.id, nextEffort);
              setIsOpen(false);
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
                },
                type: "button",
              }, effort === "extra-high" ? "Extra high" : effort)),
            )
            : null,
        )),
      )
      : null,
  );
}
