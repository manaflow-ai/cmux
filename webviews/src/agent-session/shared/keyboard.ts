export type ComposingEnterEvent = {
  key: string;
  isComposing?: boolean;
  keyCode?: number;
};

export type PlanModeShortcutEvent = {
  altKey?: boolean;
  ctrlKey?: boolean;
  key: string;
  metaKey?: boolean;
  shiftKey?: boolean;
};

export function isComposingEnter(event: ComposingEnterEvent, editorIsComposing = false): boolean {
  return event.key === "Enter" && (event.isComposing === true || editorIsComposing || event.keyCode === 229);
}

export function isPlanModeShortcut(event: PlanModeShortcutEvent): boolean {
  return event.key === "Tab" && event.shiftKey === true && !event.altKey && !event.ctrlKey && !event.metaKey;
}
