import { copyText } from "./conversation/clipboard";
import { t } from "./i18n";
import { sessionLink } from "./links";
import { SHORTCUT_ACTIONS, useShortcut, withShortcut } from "./shortcuts";
import { LinkIcon } from "./sidebarIcons";

/// The header's Copy chat link: copies `<scheme>://session/<id>` (links.ts `sessionLink`). Its
/// tooltip names Copy Tab Link's shortcut, which copies the same link from the app. Absent while the
/// chat has no session yet or the host gave no link scheme.
export function CopyChatLink({
  sessionId,
  copy = copyText,
}: {
  sessionId?: string;
  copy?: (text: string) => Promise<void>;
}) {
  const shortcut = useShortcut(SHORTCUT_ACTIONS.copyTabLink);
  const link = sessionId ? sessionLink(sessionId) : undefined;
  if (!link) return null;
  const label = t("link.copyChat");
  return (
    <button
      type="button"
      className="acpmux-copy-link"
      aria-label={label}
      title={withShortcut(label, shortcut)}
      onClick={() => void copy(link).catch(() => undefined)}
    >
      <LinkIcon />
    </button>
  );
}
