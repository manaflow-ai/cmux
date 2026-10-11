// The Cmd-K conversation switcher, ranked by the command palette's own ranker (rankPalette) so it
// matches the palette's fuzzy and acronym rules. The shared primitives own the keyboard, roles and
// focus: ui/Dialog traps focus, makes the page behind inert, closes on a press outside and returns
// focus; ui/Combobox owns the combobox and listbox roles, the arrows and the highlighted row.
// The best match is always highlighted; Return opens the highlighted conversation, Escape closes.
import { useMemo, useState, type KeyboardEvent } from "react";
import { rankPalette, type PaletteRankEntry } from "../../palette/ranker";
import { Combobox } from "../../ui/Combobox";
import { Dialog } from "../../ui/Dialog";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { conversationName } from "./model";
import type { HomeConversation } from "./types";

export interface SwitcherProps {
  conversations: ReadonlyMap<string, HomeConversation>;
  me?: string;
  strings: Strings;
  onPick(id: string): void;
  onClose(): void;
}

export function Switcher({ conversations, me, strings, onPick, onClose }: SwitcherProps) {
  const [query, setQuery] = useState("");
  const list = useMemo(() => [...conversations.values()].sort((a, b) => b.updatedAt - a.updatedAt), [conversations]);
  const entries = useMemo<PaletteRankEntry[]>(
    () =>
      list.map((c) => ({
        title: conversationName(c, me),
        keywords: c.participants.map((p) => p.name),
        isVisibleWhenQueryEmpty: true,
      })),
    [list, me],
  );
  const results = useMemo(() => {
    const ranked = rankPalette({ entries, query });
    return ranked.flatMap((section) => section.rows.map((row) => list[row.index]!)).slice(0, 50);
  }, [entries, list, query]);
  const byId = useMemo(() => new Map(results.map((c) => [c.id, c])), [results]);
  // The suggestions are conversation ids; Return without a highlighted row opens the best match.
  const submit = (value: string) => {
    const found = byId.get(value) ?? results[0];
    if (found) onPick(found.id);
  };
  // Tab would complete the field to a conversation id; the switcher has nothing to complete.
  // Option-Up/Down move the rail (useHomeKeys); they must not change the conversation behind the dialog.
  const onCommand = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Tab" || (event.altKey && (event.key === "ArrowUp" || event.key === "ArrowDown")))
      event.preventDefault();
  };
  const label = strings.t("switcher.placeholder");
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={strings.t("rail.jump")}
      className="hc-switcher"
      backdropClassName="hc-scrim"
    >
      <Combobox
        suggestions={results.map((c) => c.id)}
        onQuery={setQuery}
        onSubmit={submit}
        onCancel={onClose}
        label={label}
        placeholder={label}
        inline
        autoHighlight="always"
        cancelOnBlur={false}
        onCommand={onCommand}
        inputClassName="hc-switcher-input"
        listClassName="hc-switcher-list"
        itemClassName="hc-switcher-row"
        renderItem={(id) => {
          const c = byId.get(id);
          if (!c) return null;
          return (
            <>
              {c.kind === "group" ? (
                <span className="hc-hash">#</span>
              ) : (
                <Avatar participant={c.participants.find((p) => p.id !== me)} size={16} />
              )}
              <span className="hc-rail-name">{conversationName(c, me)}</span>
              {c.unread > 0 && <span className="hc-badge subtle">{c.unread}</span>}
            </>
          );
        }}
      />
      {results.length === 0 && <p className="hc-switcher-none">{strings.t("switcher.none")}</p>}
    </Dialog>
  );
}
