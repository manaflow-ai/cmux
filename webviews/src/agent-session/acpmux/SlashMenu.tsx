import React, { useLayoutEffect, useRef, useState } from "react";
import { useEscapingList } from "../../ui/popupHost";
import { Listbox } from "../../ui/Listbox";
import { useComposerListBox } from "./backdropLayerModel";
import { BoltIcon } from "./BoltIcon";
import { COMPOSER_LABELS } from "./composerModel";
import { useT } from "./i18n";
import { isFastCommand, returnPicks, shownName, type SlashCommand, type SlashMatch } from "./slashCommands";
import { useOutcomeHints } from "./composerOutcomeHintsModel";
import {
  SLASH_MAX_VIEWPORT_PX,
  SLASH_ROW_PX,
  slashActiveAfterScroll,
  slashScrollForActive,
  slashViewport,
} from "./slashViewport";

/**
 * The composer's `/` list, the one New Tab's box and the agent chat's composer both open: one line
 * per command: its name (its typed letters bold), what it does in the quiet second tone, and, dim at
 * its end, where it comes from (cmux, a skill, a prompt, an extension) when the list holds more than
 * one source. The highlighted row also shows its arguments (Leo 2026-11-22, bringing descriptions
 * back on every row: "when you do /, it's ... lonely when you see a field of empty" names).
 * At most 8 rows show before it scrolls (styles.css, slashViewport.ts). Its layer (backdropLayer.tsx
 * ComposerListLayer) stands it beside the box on the side with room, in the box's corners; in the
 * host's native panel past the window's edge, where a pane is too short for a few rows, a row reads
 * "/name <args> — what it does".
 */
export function SlashMenu({
  matches,
  query,
  active,
  empty,
  fast,
  onHover,
  onPick,
}: {
  matches: SlashMatch[];
  /** The typed word without `/`, shared with the composer's Return handler. */
  query: string;
  active: number;
  empty: string;
  /// The chat's fast mode, which the /fast row's sentence follows (undefined: not reported).
  fast?: "on" | "off";
  onHover(index: number): void;
  onPick(command: SlashCommand): void;
}) {
  const t = useT();
  const showOutcomeHints = useOutcomeHints().rows;
  const list = useRef<HTMLDivElement>(null);
  // Above the composer's box, or past the window's edge when the pane has no room there (cx-6k6cg).
  // The list draws out of the box (backdropLayer.tsx): the box is what it stands beside.
  const box = useComposerListBox();
  // The full match list owns keyboard ranking. Only a bounded viewport gets DOM nodes.
  const virtual = matches.length > 40;
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportPx, setViewportPx] = useState(SLASH_MAX_VIEWPORT_PX);
  const [rowPx, setRowPx] = useState(SLASH_ROW_PX);
  const wantedTop = virtual ? slashScrollForActive(active, matches.length, scrollTop, viewportPx, rowPx) : 0;
  const view = slashViewport(matches.length, wantedTop, viewportPx, rowPx);

  // Above the composer, or past the window's edge when the pane has no room there (cx-6k6cg).
  // The escape follows the glass shell; the rows' viewport (list) is what scrolls and fades.
  const escape = useEscapingList("top", 6, undefined, box, true);
  // The menu may be squeezed below its CSS cap (8 rows) in a short pane.
  useLayoutEffect(() => {
    const node = list.current;
    if (!node || !virtual) return;
    const measure = () => {
      if (node.clientHeight <= 0) return;
      const css = node.ownerDocument.defaultView?.getComputedStyle(node);
      const padding = (parseFloat(css?.paddingTop ?? "0") || 0) + (parseFloat(css?.paddingBottom ?? "0") || 0);
      const height = Math.max(1, node.clientHeight - padding);
      setViewportPx((old) => (old === height ? old : height));
      const row = node.querySelector<HTMLElement>(".acpmux-slash-row");
      const measuredRow = row?.getBoundingClientRect().height ?? 0;
      if (measuredRow > 0 && Number.isFinite(measuredRow)) {
        setRowPx((old) => (Math.abs(old - measuredRow) < 0.5 ? old : measuredRow));
      }
    };
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    const row = node.querySelector<HTMLElement>(".acpmux-slash-row");
    if (row) observer.observe(row);
    return () => observer.disconnect();
  }, [virtual, matches.length]);

  useLayoutEffect(() => {
    const node = list.current;
    if (!node) return;
    if (virtual) {
      if (Math.abs(node.scrollTop - view.scrollTop) > 0.5) node.scrollTop = view.scrollTop;
      return;
    }
  }, [virtual, view.scrollTop]);

  const describe = (match: SlashMatch) =>
    isFastCommand(match.command)
      ? t(
          fast === "on"
            ? "composer.slashFastOff"
            : fast === "off"
              ? "composer.slashFastOn"
              : "composer.slashFastToggle",
        )
      : match.command.descriptionKey
        ? t(match.command.descriptionKey)
        : match.command.description;

  // Where a command comes from, one word; none for the agent's own commands.
  const sourceTag = ({ command }: SlashMatch) =>
    !command.source || command.source === "agent"
      ? ""
      : command.source === "skill"
        ? t("composer.slashSkill")
        : command.source === "prompt"
          ? t("composer.slashPrompt")
          : command.source === "extension"
            ? (command.extension ?? "cmux")
            : "cmux";
  // A tag every row shares tells no row apart: the tags show only for a list of more than one source.
  const tagged = new Set(matches.map(sourceTag)).size > 1;

  // A native select or datalist cannot hold the matched-name bolding and descriptions.
  return (
    <Listbox
      listRef={list}
      shellRef={escape}
      items={matches}
      getKey={(match) => `${match.command.source ?? "agent"}:${match.command.name}`}
      textValue={(match) => shownName(match.command)}
      label={t(COMPOSER_LABELS.commands)}
      autoFocus={false}
      activeIndex={active}
      onActiveIndexChange={onHover}
      onOpen={(match) => onPick(match.command)}
      getItemId={(_, index) => `acpmux-slash-${index}`}
      shellClassName="ui-popup ui-glass acpmux-slash-menu"
      id="acpmux-slash-menu"
      rowClassName="acpmux-slash-row"
      empty={<div className="acpmux-slash-empty">{empty}</div>}
      window={virtual ? view : undefined}
      itemAttributes={(_, index) => ({
        "aria-posinset": String(index + 1),
        "aria-setsize": String(matches.length),
      })}
      onScroll={
        virtual
          ? (event) => {
              const top = event.currentTarget.scrollTop;
              setScrollTop(top);
              const next = slashViewport(matches.length, top, viewportPx, rowPx);
              const selected = slashActiveAfterScroll(active, matches.length, next);
              if (selected !== active) onHover(selected);
            }
          : undefined
      }
      renderItem={(match, index) => {
        // The harness's /fast reads as ChatGPT's Fast row: bolt, name, current mode.
        const fastRow = isFastCommand(match.command);
        const highlighted = index === active;
        const picks = returnPicks(match, query);
        const fastName = t("picker.tierFast");
        return (
          <>
            {fastRow && (
              <span className="acpmux-slash-icon">
                <BoltIcon size={14} />
              </span>
            )}
            <span className="acpmux-slash-name">
              {fastRow ? (
                // The typed letters stay bold where the shown name spells the command (English).
                fastName.toLowerCase() === match.command.name.toLowerCase() ? (
                  <Highlighted name={fastName} ranges={match.ranges} />
                ) : (
                  fastName
                )
              ) : (
                <>
                  /<Highlighted name={shownName(match.command)} ranges={match.ranges} />
                </>
              )}
            </span>
            {highlighted && !fastRow && match.command.hint && (
              <>
                {" "}
                <span className="acpmux-slash-hint">{match.command.hint}</span>
              </>
            )}
            {tagged && sourceTag(match) && (
              <span className="acpmux-slash-source" data-popup-skip>
                {sourceTag(match)}
              </span>
            )}
            {describe(match) && (
              <span className="acpmux-slash-description" data-popup-detail>
                {describe(match)}
              </span>
            )}
            {showOutcomeHints && highlighted && (
              <span className="acpmux-slash-actions" data-popup-skip>
                <kbd className="acpmux-slash-keycap">↩</kbd>
                {t(picks ? "composer.actionInsert" : "newTabPage.row.command")}
                {!picks && (
                  <>
                    <kbd className="acpmux-slash-keycap">⇥</kbd>
                    {t("composer.actionComplete")}
                  </>
                )}
              </span>
            )}
          </>
        );
      }}
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
