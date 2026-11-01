import React, { useState } from "react";
import {
  Menu,
  MenuButton,
  MenuCheckboxItem,
  MenuGroup,
  MenuItem,
  MenuPopup,
  MenuSearchField,
  Submenu,
} from "../../../ui/Menu";
import { agentName } from "../agents";
import { BuildIcon, PaperclipIcon } from "../ComposerPickers";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { TOOL_KINDS, type ChatTool, type ChatToolKind, type ToolApplied } from "./chatTools";

const ROW_ICON = rowIconSize(12);
/// More rows than this: a search field above them.
const SEARCH_FROM = 8;

const GROUPS: Record<ChatToolKind, StringKey> = {
  cmux: "summary.tools.group.cmux",
  mcp: "summary.tools.group.mcp",
  plugin: "summary.tools.group.plugin",
  skill: "summary.tools.group.skill",
};

/// acpmux's refusals of `_acpmux/set_tools`, as the row says them (hub/tools.rs, remote_guard.rs).
const REFUSALS: Record<string, StringKey> = {
  "tools.fixed": "summary.tools.fixed",
  "tools.immutable": "summary.tools.immutable",
  "tools.remote": "summary.tools.remote",
};

/// What a row says after its last change: when it applies, or why it was refused.
type Note = { kind: "afterTurn" | "nextStart" } | { kind: "error"; text: StringKey };

export type ChatToolsControl = {
  rows: readonly ChatTool[];
  /// `_acpmux/set_tools` for the chat; resolves with when the change applies.
  set: (id: string, enabled: boolean) => Promise<ToolApplied>;
};

/// Sources' + when the chat's tools can change (cx-thur3): Attach files or folders (a chat on this
/// computer) and Use tools, a submenu of the chat's tools grouped as acpmux reports them, each on or
/// off for this chat. A toggle shows at once; acpmux's answer says when it applies (After this
/// turn, Next time the chat starts) on its row, and a refusal puts the row back and says why there.
/// Nothing modal: the menu stays open on a toggle.
export function SourcesAddMenu({ attach, tools }: { attach?: () => void; tools: ChatToolsControl }) {
  const t = useT();
  const [query, setQuery] = useState("");
  // A toggle waiting for acpmux, shown as it will be; then its note.
  const [pending, setPending] = useState<ReadonlyMap<string, boolean>>(new Map());
  const [notes, setNotes] = useState<ReadonlyMap<string, Note>>(new Map());
  const label = t("summary.sources.add");
  const toggle = (tool: ChatTool, enabled: boolean) => {
    setPending((current) => new Map(current).set(tool.id, enabled));
    const note = (next: Note | undefined) =>
      setNotes((current) => {
        const map = new Map(current);
        if (next) map.set(tool.id, next);
        else map.delete(tool.id);
        return map;
      });
    note(undefined);
    tools
      .set(tool.id, enabled)
      .then(
        (applied) => note(applied === "now" ? undefined : { kind: applied }),
        (error: unknown) => {
          const reason = (error as { reason?: unknown } | null)?.reason;
          const text =
            typeof reason === "string" && Object.hasOwn(REFUSALS, reason) ? REFUSALS[reason] : "summary.tools.failed";
          note({ kind: "error", text });
        },
      )
      .finally(() =>
        setPending((current) => {
          const map = new Map(current);
          map.delete(tool.id);
          return map;
        }),
      );
  };
  const needle = query.trim().toLowerCase();
  const shown = needle
    ? tools.rows.filter((tool) => `${tool.name} ${tool.source}`.toLowerCase().includes(needle))
    : tools.rows;
  const noteText = (note: Note) =>
    note.kind === "error"
      ? t(note.text)
      : t(note.kind === "afterTurn" ? "summary.tools.afterTurn" : "summary.tools.nextStart");
  return (
    <Menu onOpenChange={(open) => open || setQuery("")}>
      <MenuButton className="acpmux-summary-add" label={label} title={label} data-menu="summary-sources-add">
        <Icon name="action.add" size={ROW_ICON} />
      </MenuButton>
      <MenuPopup className="acpmux-chat-menu-popover acpmux-summary-menu" align="end">
        {attach && (
          <MenuItem className="acpmux-chat-menu-item" onSelect={attach}>
            <PaperclipIcon />
            <span className="acpmux-chat-menu-label">{t("summary.sources.attach")}</span>
          </MenuItem>
        )}
        <Submenu
          className="acpmux-chat-menu-item"
          popupClassName="acpmux-chat-menu-popover acpmux-summary-menu acpmux-tools-menu"
          label={
            <>
              <BuildIcon />
              <span className="acpmux-chat-menu-label">{t("summary.tools.use")}</span>
            </>
          }
        >
          {tools.rows.length > SEARCH_FROM && (
            <MenuSearchField value={query} onChange={setQuery} label={t("summary.tools.search")} />
          )}
          {shown.length === 0 && <div className="acpmux-tools-empty">{t("summary.tools.noMatch")}</div>}
          {TOOL_KINDS.map((kind) => {
            const rows = shown.filter((tool) => tool.kind === kind);
            if (rows.length === 0) return null;
            return (
              <MenuGroup key={kind} label={t(GROUPS[kind])}>
                {rows.map((tool) => {
                  const note = notes.get(tool.id);
                  const waiting = pending.get(tool.id);
                  return (
                    <MenuCheckboxItem
                      key={tool.id}
                      className="acpmux-chat-menu-item acpmux-tools-row"
                      checked={waiting ?? tool.enabled}
                      disabled={!tool.canToggle || waiting !== undefined}
                      onCheckedChange={(next) => toggle(tool, next)}
                    >
                      <span className="acpmux-tools-name">{tool.name}</span>
                      {note ? (
                        <span className="acpmux-tools-note" data-kind={note.kind} title={noteText(note)}>
                          {noteText(note)}
                        </span>
                      ) : (
                        <span className="acpmux-tools-source">
                          {tool.source === "cmux" ? "cmux" : agentName(tool.source)}
                        </span>
                      )}
                    </MenuCheckboxItem>
                  );
                })}
              </MenuGroup>
            );
          })}
        </Submenu>
      </MenuPopup>
    </Menu>
  );
}
