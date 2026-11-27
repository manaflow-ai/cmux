import { useEscapingList } from "../../ui/popupHost";
import { useComposerListBox } from "./backdropLayerModel";
import { type Run } from "./fileSearchModel";
import { Icon } from "./icons/Icon";
import type { MentionItem } from "./mentionItems";
import { Listbox } from "../../ui/Listbox";
import { useT } from "./i18n";
import { FileSearchLoading } from "./FileSearchLoading";
import { type MentionState } from "./mentionMenuModel";
import { TOOL_MENTIONS, type ToolMentionId } from "./toolMentions";
/// The picker under the prompt, styled as the slash menu: the plugins, then folders and files
/// (mentionItems.ts), each with its icon, its name with the matched letters bold and its line or
/// folder muted beside it. The prompt keeps focus and its keys (Composer.tsx): arrows move, Return
/// or Tab picks, Esc closes. `state` is the file search's, undefined in a chat whose folder cannot be
/// searched (a remote chat), which says nothing of files. `active` -1: no row.
export function MentionMenu({
  state,
  items,
  active,
  onHover,
  onPick,
}: {
  state: MentionState | undefined;
  items: readonly MentionItem[];
  active: number;
  onHover(index: number): void;
  onPick(item: MentionItem): void;
}) {
  const t = useT();
  // Above the composer's box, or past the window's edge when the pane has no room there (cx-6k6cg).
  // The list draws out of the box (backdropLayer.tsx): the box is what it stands beside.
  const box = useComposerListBox();
  const escape = useEscapingList("top", 6, undefined, box, true);
  // The file search speaks only when the menu has no row to show: under a plugin or a chat, its state
  // ("Couldn't search files" in a chat with no folder) is noise (Lucas 2026-11-21). A failed search then
  // reads as no files, never as an error under rows that work.
  const note =
    !state || items.length > 0
      ? undefined
      : state.kind === "idle"
        ? t("files.hint")
        : t(state.kind === "searching" ? "files.searching" : "files.none");
  return (
    <>
      <Listbox
        shellRef={escape}
        items={items}
        getKey={(item) => item.key}
        textValue={(item) => item.name.map((part) => part.text).join("")}
        label={t("files.search")}
        autoFocus={false}
        activeIndex={active}
        onActiveIndexChange={onHover}
        onOpen={onPick}
        aria-busy={state?.kind === "searching"}
        getItemId={(_, index) => `acpmux-mention-${index}`}
        itemAttributes={(item) => ({ "data-mention-kind": item.kind })}
        shellClassName="ui-popup ui-glass acpmux-slash-menu acpmux-mention-menu"
        id="acpmux-mention-menu"
        rowClassName="acpmux-slash-row acpmux-mention-row"
        empty={state?.kind === "searching" && items.length === 0 ? <FileSearchLoading mention /> : undefined}
        footer={
          note ? (
            <output className={state?.kind === "searching" ? "acpmux-file-loading-note" : "acpmux-file-note"}>
              {note}
            </output>
          ) : undefined
        }
        renderItem={(item) => (
          <>
            <span className="acpmux-mention-icon" data-mention-icon={item.kind}>
              {item.kind === "tool" && toolImage(item.toolId) ? (
                <img
                  className="acpmux-tool-image"
                  src={toolImage(item.toolId)}
                  width={14}
                  height={14}
                  alt=""
                  draggable={false}
                />
              ) : (
                <Icon
                  name={item.kind === "harness" ? "agent.chat" : item.kind === "tool" ? item.icon : item.kind}
                  size={14}
                />
              )}
            </span>
            <span className="acpmux-slash-name">{runs(item.name)}</span>
            {item.kind === "extension" ? (
              <span className="acpmux-slash-description">{item.mention.detail ?? item.mention.extension}</span>
            ) : item.kind === "harness" ? (
              <span className="acpmux-slash-description">{t("mention.readOnlyGuest")}</span>
            ) : item.kind === "tool" ? (
              <span className="acpmux-slash-description">{t(toolHint(item.toolId))}</span>
            ) : (
              item.dir.length > 0 && <span className="acpmux-slash-description">{runs(item.dir)}</span>
            )}
          </>
        )}
      />
    </>
  );
}

function runs(parts: readonly Run[]) {
  return parts.map((part, index) => (part.matched ? <b key={index}>{part.text}</b> : part.text));
}

const toolHint = (id: ToolMentionId) => TOOL_MENTIONS.find((tool) => tool.id === id)!.hint;
const toolImage = (id: ToolMentionId) => TOOL_MENTIONS.find((tool) => tool.id === id)?.image;
