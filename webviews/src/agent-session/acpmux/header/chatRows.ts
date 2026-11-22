import type { ChatMenuChild, ChatMenuItem } from "./chatHeaderToolsModel";
import type { Translate } from "../i18n";

type Row = Exclude<ChatMenuItem, "separator">;

/// The chat menu's Move to… row: every place the host says the chat can go (this Mac and the Cloud
/// machines, `moveTargets`), and Bring Back Local when no target names this Mac. It was the title's
/// menu row until the title became plain text (Leo, 2026-11-01: "why is there a dropdown of this");
/// no target is dropped.
export function moveMachineRow(
  {
    move,
    bringBack,
    targets,
  }: {
    move: boolean;
    bringBack: boolean;
    targets: readonly { id: string; label: string; kind?: "local" | "cloud"; reason?: string }[];
  },
  run: { moveTo: (id: string) => void; bringBack: () => void },
  t: Translate,
): Row | undefined {
  const local = targets.some((target) => target.kind === "local");
  const children: ChatMenuChild[] = [
    ...targets
      .filter((target) => !target.reason)
      .map((target) => ({
        key: `machine:${target.id}`,
        label: target.kind === "local" ? t("composer.thisMac") : target.label,
        onSelect: () => run.moveTo(target.id),
      })),
    ...(bringBack && !local
      ? [{ key: "bringBack", label: t("composer.bringBackLocal"), onSelect: run.bringBack }]
      : []),
  ];
  // Nowhere to move: no row, rather than a disabled one in a long menu.
  if (children.length === 0) return undefined;
  return {
    key: "moveMachine",
    label:
      move || targets.length > 0
        ? t("composer.moveToMenu")
        : children.length === 1
          ? children[0]!.label
          : t("composer.environment"),
    icon: "machine.remote",
    children,
  };
}

/// The chat menu's Delete row (header/DeleteChatDialog.tsx confirms it), with Archive in the last group.
export function deleteChatRow(requestDelete: () => void, t: Translate): Row {
  return { key: "delete", label: t("permission.verb.delete"), icon: "action.delete", onSelect: requestDelete };
}
