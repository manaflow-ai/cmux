import type { Translate } from "../i18n";
import type { QuickAction, QuickActionId, QuickActionMode } from "./quickActions";
import { HEADER_ACTIONS } from "./headerActions";

export interface HeaderQuickTool {
  id: QuickActionId;
  icon: string;
  label: string;
  title?: string;
  pressed?: boolean;
  run?: () => void;
}

export interface HeaderQuickToolsInput {
  actions: readonly QuickAction[];
  tabTools: boolean;
  sideTabs: boolean;
  lit: readonly string[];
  hasChanges: boolean;
  previewUrl?: string;
  onTerminal(mode: QuickActionMode): void;
  onBrowser(mode: QuickActionMode): void;
  onSplitDown?: (mode: QuickActionMode) => void;
  onChanges?: (mode: QuickActionMode) => void;
  onFiles?: (mode: QuickActionMode) => void;
  onPreview?: (url: string | undefined, mode: QuickActionMode) => void;
  onSideTabs?: () => void;
  t: Translate;
}

/// One list of visible quick actions and handlers, shared by the web and native buttons.
export function headerQuickTools(input: HeaderQuickToolsInput): HeaderQuickTool[] {
  const {
    actions,
    tabTools,
    sideTabs,
    lit,
    hasChanges,
    previewUrl,
    onTerminal,
    onBrowser,
    onSplitDown,
    onChanges,
    onFiles,
    onPreview,
    onSideTabs,
    t,
  } = input;
  if (!tabTools) return [];
  const on = (action: string, mode: QuickActionMode) => (mode === "toggle" ? lit.includes(action) : undefined);
  const address = () => {
    try {
      const url = new URL(previewUrl!);
      return `${url.host}${url.pathname === "/" ? "" : url.pathname}${url.search}`;
    } catch {
      return previewUrl!;
    }
  };
  const previewTitle = () => (previewUrl ? t("header.previewAddress", { address: address() }) : undefined);
  return actions.flatMap(({ id, mode }): HeaderQuickTool[] => {
    switch (id) {
      case "newTab":
        return [
          {
            id,
            icon: sideTabs ? "tunable.sidebar" : "action.add",
            label: t(sideTabs ? "header.hideTabs" : "header.newTab"),
            pressed: sideTabs,
            run: onSideTabs,
          },
        ];
      case "changes":
        return onChanges && (hasChanges || lit.includes(HEADER_ACTIONS.changes))
          ? [
              {
                id,
                icon: "diff.file",
                label: t("header.changes"),
                pressed: on(HEADER_ACTIONS.changes, mode),
                run: () => onChanges(mode),
              },
            ]
          : [];
      case "files":
        return onFiles
          ? [
              {
                id,
                icon: "folder",
                label: t("header.files"),
                pressed: on(HEADER_ACTIONS.files, mode),
                run: () => onFiles(mode),
              },
            ]
          : [];
      case "preview":
        return onPreview && (previewUrl || on(HEADER_ACTIONS.preview, mode))
          ? [
              {
                id,
                icon: "media.play",
                label: t("header.preview"),
                title: previewTitle(),
                pressed: on(HEADER_ACTIONS.preview, mode),
                run: () => onPreview(previewUrl, mode),
              },
            ]
          : [];
      case "splitDown":
        return onSplitDown
          ? [
              {
                id,
                icon: "pane.split.down",
                label: t("header.splitDown"),
                pressed: on(HEADER_ACTIONS.splitDown, mode),
                run: () => onSplitDown(mode),
              },
            ]
          : [];
      case "terminal":
        return [
          {
            id,
            icon: "terminal",
            label: t("header.terminal"),
            pressed: on(HEADER_ACTIONS.terminal, mode),
            run: () => onTerminal(mode),
          },
        ];
      case "browser":
        // Always a new, blank browser, never the chat's local page (https://github.com/manaflow-ai/cmux/issues/49623).
        // That page was often an address the agent only mentioned (a dev build's Tag Opener link),
        // and opening it again relaunched the build. The page stays one click away as Preview, a
        // button or a "..." row.
        return [
          {
            id,
            icon: "browser",
            label: t("header.browser"),
            pressed: on(HEADER_ACTIONS.browser, mode),
            run: () => onBrowser(mode),
          },
        ];
    }
  });
}
