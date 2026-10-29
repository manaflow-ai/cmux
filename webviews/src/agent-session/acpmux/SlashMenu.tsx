import { useEffect, useState } from "react";
import type { NativePopupEvent, NativePopupRow } from "../../ui/nativePopup";
import { useComposerPopup, popupChoice } from "./nativeComposerPopup";
import { useT } from "./i18n";
import type { SlashCommand, SlashMatch } from "./slashCommands";
import { isFastCommand } from "./slashCommands";

export function SlashMenu({
  matches,
  active,
  empty,
  fast,
  query = "",
  anchor,
  onSearch,
  onHover,
  onPick,
}: {
  matches: SlashMatch[];
  active: number;
  empty: string;
  fast?: "on" | "off";
  query?: string;
  anchor: () => HTMLElement | null;
  onSearch?(value: string): void;
  onHover(index: number): void;
  onPick(command: SlashCommand): void;
}) {
  const t = useT();
  const [open, setOpen] = useState(true);
  const matchById = new Map(
    matches.map((match) => [match.command.name, match]),
  );
  const rows: NativePopupRow[] = matches.length
    ? matches.map((match) => {
        const fastRow = isFastCommand(match.command);
        return popupChoice(
          match.command.name,
          fastRow ? t("picker.tierFast") : `/${match.command.name}`,
          {
            description: fastRow
              ? t(
                  fast === "on"
                    ? "composer.slashFastOff"
                    : fast === "off"
                      ? "composer.slashFastOn"
                      : "composer.slashFastToggle",
                )
              : match.command.descriptionKey
                ? t(match.command.descriptionKey)
                : match.command.description,
            checked: false,
          },
        );
      })
    : [{ id: "empty", kind: "text", label: empty }];

  useEffect(() => {
    setOpen(true);
  }, [matches.length]);
  useComposerPopup({
    open,
    anchor,
    model: {
      side: "top",
      align: "start",
      width: 360,
      title: t("composer.commands"),
      search: {
        id: "query",
        value: query,
        placeholder: t("composer.commands"),
      },
      rows,
      highlighted: matches[active]?.command.name,
    },
    onEvent: (event: NativePopupEvent) => {
      if (event.type === "search") {
        if (event.value !== undefined) onSearch?.(event.value);
        return;
      }
      if (event.type === "highlight" && event.id) {
        const index = matches.findIndex(
          (match) => match.command.name === event.id,
        );
        if (index >= 0) onHover(index);
        return;
      }
      if (event.type === "pick" && event.id) {
        const match = matchById.get(event.id);
        if (match) onPick(match.command);
      }
    },
    onDismiss: () => setOpen(false),
  });
}
