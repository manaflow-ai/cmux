import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import { toolOfHref, TOOL_HREF_PREFIX, type ToolMentionId } from "../toolMentions";

/// `@computer-use` / `@browser-use` in a sent message, drawn as the badge the composer drew it as
/// (composer/deeplinkTitles.ts; Lucas 2026-11-21: "make sure in the chats that browser use and computer
/// use have their badges"): the tool's icon and name on the session link chip's wash (cmuxLinkChip.css).
/// A hover says what it does, the @ menu row's line ("Agents can use your apps when you ask them to"),
/// in the pane's own tooltip (ui/titleTooltips.ts reads `title`).
export function ToolBadge({ tool }: { tool: ToolMentionId }) {
  const t = useT();
  const info = toolOfHref(TOOL_HREF_PREFIX + tool)!;
  return (
    <span className="cv-cmux-link acpmux-started-chip cv-tool-badge" data-tool={tool} title={t(info.hint)}>
      <Icon name={info.icon} size={14} className="cv-cmux-link__icon" />
      <span className="cv-cmux-link__title">{t(info.label)}</span>
    </span>
  );
}
