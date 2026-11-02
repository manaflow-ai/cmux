import type { ChatMenuChild, ChatMenuItem } from "./ChatHeaderTools";
import type { Translate } from "../i18n";

type Row = Exclude<ChatMenuItem, "separator">;

/// The chat menu's Move to machine row: the host's Cloud targets (MachineRegistry, through the
/// existing CloudMove action) and Bring Back Local. It was the title's menu row until the title
/// became plain text (Leo, 2026-11-01: "why is there a dropdown of this"); no target is dropped.
export function moveMachineRow(
  {
    move,
    bringBack,
    targets,
  }: { move: boolean; bringBack: boolean; targets: readonly { id: string; label: string }[] },
  run: { moveTo: (id: string) => void; bringBack: () => void },
  t: Translate,
): Row | undefined {
  const children: ChatMenuChild[] = [
    ...(move
      ? targets.map((target) => ({
          key: `machine:${target.id}`,
          label: target.label,
          onSelect: () => run.moveTo(target.id),
        }))
      : []),
    ...(bringBack ? [{ key: "bringBack", label: t("composer.bringBackLocal"), onSelect: run.bringBack }] : []),
  ];
  // Nowhere to move: no row, rather than a disabled one in a long menu.
  if (children.length === 0) return undefined;
  return {
    key: "moveMachine",
    label: move ? t("chatMenu.moveToMachine") : children.length === 1 ? children[0]!.label : t("composer.environment"),
    icon: "machine.remote",
    children,
  };
}

/// The chat menu's Delete row (header/DeleteChatDialog.tsx confirms it), with Archive in the last group.
export function deleteChatRow(requestDelete: () => void, t: Translate): Row {
  return { key: "delete", label: t("permission.verb.delete"), icon: "action.delete", onSelect: requestDelete };
}
