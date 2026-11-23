export type ToolbarButton = { action: string; label?: string };

export function toolbarButtonsFrom(reply: unknown): ToolbarButton[] {
  const buttons = (reply as { toolbarButtons?: unknown } | null)?.toolbarButtons;
  if (!Array.isArray(buttons)) return [];
  return buttons.filter(
    (button): button is ToolbarButton =>
      typeof button?.action === "string" &&
      !!button.action &&
      (button.label === undefined || typeof button.label === "string"),
  );
}
