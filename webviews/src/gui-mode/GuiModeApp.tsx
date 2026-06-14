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
} from "./bridge";

const h = React.createElement;

type LoadState =
  | { status: "ready"; context: GuiModeContext }
  | { status: "error"; message: string };

const defaultContext: GuiModeContext = {
  copy: {
    errorMessage: "Could not create the GUI workspace.",
    homeTitle: "GUI Mode",
    promptPlaceholder: "What should cmux build?",
    submit: "Submit",
    submitting: "Submitting",
    taskPromptLabel: "Prompt",
    taskTitle: "/task-worktree-pr",
  },
  page: "home",
  prompt: "",
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
        : h(GuiModeHomePage, { context: loadState.context }),
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
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState("");
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const trimmedPrompt = prompt.trim();
  const canSubmit = trimmedPrompt.length > 0 && !isSubmitting;
  const submit = useCallback(() => {
    if (!canSubmit) {
      return;
    }
    setIsSubmitting(true);
    setError("");
    void submitGuiModePrompt(trimmedPrompt)
      .catch(() => setError(context.copy.errorMessage))
      .finally(() => setIsSubmitting(false));
  }, [canSubmit, context.copy.errorMessage, trimmedPrompt]);

  return h("section", { className: "gui-mode-home", "aria-label": context.copy.homeTitle },
    h("div", { className: CODEX_COMPOSER_STACK },
      h("div", { className: CODEX_COMPOSER_FRAME },
        h("div", { className: `${CODEX_COMPOSER_SURFACE} gui-mode-composer` },
          h("div", { className: CODEX_COMPOSER_INNER },
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
  return h("section", { className: "gui-mode-task", "aria-label": context.copy.taskTitle },
    h("div", { className: "gui-mode-task-panel" },
      h("div", { className: "gui-mode-task-label" }, context.copy.taskPromptLabel),
      h("div", { className: "gui-mode-task-prompt" }, context.prompt),
    ),
  );
}
