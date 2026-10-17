// The thread's place at the top of Thread details (Lucas 2026-10-17, Codex and Conductor's thread
// details): its project folder with Open in (the apps the host lists, `folder.openIn`), the branch
// with how far it is from its upstream and its base, and the commit HEAD is on (a click copies it).
// Read from the folder's `git.status`; a chat with no folder on this Mac shows nothing here.
import { useEffect, useState } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { copyText } from "../conversation/clipboard";
import type { GitStatus } from "../changes/model";
import { ChevronDown } from "../conversation/icons";

const ROW_ICON = rowIconSize(12);

export type OpenInApp = { id: string; name: string };

/// The folder's last part, as the header's project shows it.
export const folderName = (folder: string) => folder.replace(/\/+$/, "").split("/").pop() || folder;

export function ThreadDetails({
  folder,
  readStatus,
  refresh,
  openIn,
}: {
  folder?: string;
  readStatus?: (cwd: string) => Promise<unknown>;
  /// Read the status again when this changes (a turn ending).
  refresh?: unknown;
  /// The host's Open in (`folder.openIn`): no app lists the apps; an app opens the folder there.
  openIn?: (app?: string) => Promise<OpenInApp[]>;
}) {
  const t = useT();
  const [status, setStatus] = useState<{ folder: string; value: GitStatus & { head?: string } }>();
  const [apps, setApps] = useState<OpenInApp[]>();
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!folder || !readStatus) return;
    let current = true;
    readStatus(folder).then(
      (value) => current && value && setStatus({ folder, value: value as GitStatus & { head?: string } }),
      () => current && setStatus(undefined),
    );
    return () => {
      current = false;
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the status is the folder's: a new reader asks nothing new
  }, [folder, refresh]);
  if (!folder) return null;
  const git = status?.folder === folder ? status.value : undefined;
  const head = git?.head?.slice(0, 7);
  const away = [git?.ahead ? `↑${git.ahead}` : "", git?.behind ? `↓${git.behind}` : ""].filter(Boolean).join(" ");
  return (
    <section className="acpmux-summary-section acpmux-thread-details" aria-label={t("summary.threadDetails")}>
      <ul className="acpmux-summary-list">
        <li className="acpmux-summary-row acpmux-thread-details__row" title={folder}>
          <Icon name="folder" size={ROW_ICON} row />
          <span className="acpmux-summary-text">{folderName(folder)}</span>
          {openIn && (
            <Menu
              onOpenChange={(open) => {
                if (open) void openIn().then(setApps, () => setApps([]));
              }}
            >
              <MenuButton className="acpmux-thread-details__open" label={t("preview.openIn")}>
                {t("preview.openIn")}
                <ChevronDown size={11} />
              </MenuButton>
              <MenuPopup align="end">
                {(apps ?? []).map((app) => (
                  <MenuItem key={app.id} onSelect={() => void openIn(app.id).catch(() => undefined)}>
                    {app.name}
                  </MenuItem>
                ))}
              </MenuPopup>
            </Menu>
          )}
        </li>
        {git?.branch && (
          <li className="acpmux-summary-row acpmux-thread-details__row">
            <Icon name="git.branch" size={ROW_ICON} row />
            <span className="acpmux-summary-text">{git.branch}</span>
            {(away || (git.base && git.base !== git.branch)) && (
              <span className="acpmux-summary-meta">
                {[away, git.base && git.base !== git.branch ? git.base : ""].filter(Boolean).join(" · ")}
              </span>
            )}
          </li>
        )}
        {head && (
          <li>
            <button
              type="button"
              className="acpmux-summary-row acpmux-summary-link acpmux-thread-details__row"
              title={copied ? t("turn.copied") : t("turn.copy")}
              onClick={() =>
                void copyText(git!.head!).then(
                  () => setCopied(true),
                  () => setCopied(false),
                )
              }
            >
              <Icon name="action.copy" size={ROW_ICON} row />
              <span className="acpmux-summary-text acpmux-thread-details__commit">{head}</span>
              <span className="acpmux-summary-meta">{t("git.commit.label")}</span>
            </button>
          </li>
        )}
      </ul>
    </section>
  );
}
