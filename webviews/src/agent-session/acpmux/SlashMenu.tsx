import React, { useCallback, useLayoutEffect, useRef } from "react";
import { useEscapingList } from "../../ui/popupHost";
import { useComposerListBox } from "./backdropLayer";
import { useT } from "./i18n";
import type { SlashCommand, SlashMatch } from "./slashCommands";

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
  const list = useRef<HTMLDivElement>(null);
  // Above the composer's box, or past the window's edge when the pane has no room there (cx-6k6cg).
  // The list draws out of the box (backdropLayer.tsx): the box is what it stands beside.
  const box = useComposerListBox();
  const escape = useEscapingList("top", 6, undefined, box);
  const setList = useCallback(
    (node: HTMLDivElement | null) => {
      list.current = node;
      escape?.(node);
    },
    [escape],
  );
  useLayoutEffect(() => {
    list.current?.querySelector<HTMLElement>(`#acpmux-slash-${active}`)?.scrollIntoView?.({ block: "nearest" });
  }, [active]);
  // A native select or datalist cannot hold the matched-name bolding and descriptions.
  if (matches.length === 0)
    return (
      <div
        className="ui-popup ui-glass acpmux-slash-menu acpmux-slash-empty"
        id="acpmux-slash-menu"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="listbox"
        aria-label={t("composer.commands")}
      >
        {empty}
      </div>
    );
  return (
    <div
      ref={setList}
      className="ui-popup ui-glass acpmux-slash-menu"
      id="acpmux-slash-menu"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listbox"
      aria-label={t("composer.commands")}
    >
      {/* Virtual focus: the prompt keeps focus and names the row through aria-activedescendant. */}
      {matches.map((match, index) => (
        <div
          key={match.command.name}
          id={`acpmux-slash-${index}`}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="option"
          tabIndex={-1}
          aria-selected={index === active}
          className={index === active ? "acpmux-slash-row acpmux-slash-active" : "acpmux-slash-row"}
          onMouseMove={() => {
            if (index !== active) onHover(index);
          }}
          onMouseDown={(event) => {
            event.preventDefault();
            onPick(match.command);
          }}
        >
          <span className="acpmux-slash-name">
            /<Highlighted name={match.command.name} ranges={match.ranges} />
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
        </div>
      ))}
    </div>
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
