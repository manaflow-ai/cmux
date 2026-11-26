// The chat menu's Auto rows (plans/cmux-next/auto-mode/DESIGN.md): Auto, on or off for this chat,
// and Keep in Cloud while the Cloud runs it. They sit with the chat's other Cloud rows, in the
// Move to… submenu (header/chatRows.ts `moveMachineRow`), as rows that are on or off on their own
// (Transcript view's Wrap lines draws the same check). A chat whose acpmux says nothing of Auto
// gets neither row.
import { heldInCloud, type AutoSession } from "../autoSession/autoSession";
import type { Translate } from "../i18n";
import type { ChatMenuChild } from "./chatHeaderToolsModel";

export function autoRows(
  auto: AutoSession | undefined,
  run: { setAuto: (auto: boolean) => void; keepInCloud: (keep: boolean) => void },
  t: Translate,
): ChatMenuChild[] {
  if (!auto) return [];
  const inCloud = heldInCloud(auto);
  return [
    {
      key: "auto",
      label: t("auto.menu"),
      on: auto.auto,
      // A chat the Cloud runs cannot leave Auto until it is back on this Mac: Keep in Cloud is
      // its choice meanwhile.
      disabled: inCloud,
      onSelect: () => run.setAuto(!auto.auto),
    },
    ...(inCloud
      ? [
          {
            key: "keepInCloud",
            label: t("auto.menu.keepInCloud"),
            on: auto.keepInCloud,
            onSelect: () => run.keepInCloud(!auto.keepInCloud),
          },
        ]
      : []),
  ];
}
