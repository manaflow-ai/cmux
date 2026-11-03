import React, { useCallback } from "react";
import { useEscapingList } from "../../ui/popupHost";
import { useScrollEdges } from "../../ui/scrollEdges";
import { Listbox } from "../../ui/Listbox";
import { useComposerListBox } from "./backdropLayer";
import { useT } from "./i18n";
import { shownName, type SlashCommand, type SlashMatch } from "./slashCommands";

export function SlashMenu({
  matches,
  active,
  empty,
  onHover,
  onPick,
}: {
  matches: SlashMatch[];
  active: number;
  empty: string;
  onHover(index: number): void;
  onPick(command: SlashCommand): void;
}) {
  const t = useT();
  // Above the composer's box, or past the window's edge when the pane has no room there (cx-6k6cg).
  // The list draws out of the box (backdropLayer.tsx): the box is what it stands beside.
  const box = useComposerListBox();
  const listEdges = useScrollEdges();
  const escape = useEscapingList("top", 6, undefined, box);
  const setList = useCallback(
    (node: HTMLDivElement | null) => {
      listEdges(node);
      escape?.(node);
    },
    [escape, listEdges],
  );
  // A native select or datalist cannot hold the matched-name bolding and descriptions.
  return (
    <Listbox
      listRef={setList}
      items={matches}
      getKey={(match) => `${match.command.source ?? "agent"}:${match.command.name}`}
      textValue={(match) => shownName(match.command)}
      label={t("composer.commands")}
      autoFocus={false}
      activeIndex={active}
      onActiveIndexChange={onHover}
      onOpen={(match) => onPick(match.command)}
      getItemId={(_, index) => `acpmux-slash-${index}`}
      className="ui-popup ui-glass acpmux-slash-menu"
      id="acpmux-slash-menu"
      rowClassName="acpmux-slash-row"
      empty={<div className="acpmux-slash-empty">{empty}</div>}
      renderItem={(match) => (
        <>
          <span className="acpmux-slash-name">
            /<Highlighted name={shownName(match.command)} ranges={match.ranges} />
          </span>
          {match.command.hint && <span className="acpmux-slash-hint">{match.command.hint}</span>}
          {match.command.source && match.command.source !== "agent" && (
            <span className="acpmux-slash-source">
              {match.command.source === "skill"
                ? t("composer.slashSkill")
                : match.command.source === "prompt"
                  ? t("composer.slashPrompt")
                  : "cmux"}
            </span>
          )}
          <span className="acpmux-slash-description">
            {match.command.descriptionKey ? t(match.command.descriptionKey) : match.command.description}
          </span>
        </>
      )}
    />
  );
}

function Highlighted({ name, ranges }: { name: string; ranges: [number, number][] }) {
  const parts: React.ReactNode[] = [];
  let at = 0;
  for (const [start, end] of ranges) {
    if (start > at) parts.push(name.slice(at, start));
    parts.push(<mark key={start}>{name.slice(start, end)}</mark>);
    at = end;
  }
  if (at < name.length) parts.push(name.slice(at));
  return <>{parts}</>;
}
