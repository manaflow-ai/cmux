// The thread's place at the top of Thread details (Lucas 2026-10-17, after T3 Code's thread menu): rows
// on the menu's rhythm, each an icon, its words and, where it has more, a chevron past a hairline.
// - Where: the machine and the project folder (No project for a chat in its private agent-home).
// - Open in <app>: the folder in the app last picked (else the first editor installed), with that
//   app's own icon; the chevron lists the others (`folder.openIn`).
// - The branch, how far it is from its upstream and its base; HEAD's commit, a click copies it.
// Read from the folder's `git.status`; a chat with no folder on this Mac shows nothing here.
import { useEffect, useState } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { useT } from "../i18n";
import { useNt } from "../newtab/strings";
import { Icon } from "../icons/Icon";
import { copyText } from "../conversation/clipboard";
import type { GitStatus } from "../changes/model";
import { ChevronDown } from "../conversation/icons";
import { isAgentHome } from "../sessionList";

export type OpenInApp = { id: string; name: string; icon?: string };

/// The folder's last part, as the header's project shows it.
export const folderName = (folder: string) => folder.replace(/\/+$/, "").split("/").pop() || folder;

/// The app Open in used last, per viewer (a convenience: unreadable storage just picks the first editor).
const PREFERRED = "cmux.agentPane.openIn";
const readPreferred = () => {
  try {
    return localStorage.getItem(PREFERRED) ?? undefined;
  } catch {
    return undefined;
  }
};
const writePreferred = (id: string) => {
  try {
    localStorage.setItem(PREFERRED, id);
  } catch {
    // Storage off: the pick still opens.
  }
};

function AppIcon({ app }: { app?: OpenInApp }) {
  return app?.icon?.startsWith("data:image/") ? (
    <img className="acpmux-thread-details__app" src={app.icon} alt="" width={16} height={16} />
  ) : (
    <Icon name="app.open.external" size={15} />
  );
}

export function ThreadDetails({
  folder,
  machine,
  readStatus,
  refresh,
  openIn,
}: {
  folder?: string;
  /// This Mac's name, for the Where row.
  machine?: string;
  readStatus?: (cwd: string) => Promise<unknown>;
  /// Read the status again when this changes (a turn ending).
  refresh?: unknown;
  /// The host's Open in (`folder.openIn`): no app lists the apps; an app opens the folder there.
  openIn?: (app?: string) => Promise<OpenInApp[]>;
}) {
  const t = useT();
  const nt = useNt();
  const [status, setStatus] = useState<{ folder: string; value: GitStatus & { head?: string } }>();
  const [apps, setApps] = useState<OpenInApp[]>();
  const [preferred, setPreferred] = useState(readPreferred);
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
  // The apps once, for the Open in row's own icon and name.
  useEffect(() => {
    if (!openIn) return;
    let current = true;
    openIn().then(
      (list) => current && setApps(list),
      () => current && setApps([]),
    );
    return () => {
      current = false;
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the list is the Mac's: asked once per card
  }, []);
  if (!folder) return null;
  const home = isAgentHome(folder);
  const git = status?.folder === folder ? status.value : undefined;
  const head = git?.head?.slice(0, 7);
  const away = [git?.ahead ? `↑${git.ahead}` : "", git?.behind ? `↓${git.behind}` : ""].filter(Boolean).join(" ");
  const primary = apps?.find((app) => app.id === preferred) ?? apps?.find((app) => app.id !== "finder") ?? apps?.[0];
  const open = (app: OpenInApp) => {
    writePreferred(app.id);
    setPreferred(app.id);
    void openIn?.(app.id).catch(() => undefined);
  };
  return (
    <section className="acpmux-thread-details" aria-label={t("summary.threadDetails")}>
      <div className="acpmux-thread-details__row" title={folder}>
        <span className="acpmux-thread-details__icons" aria-hidden="true">
          <Icon name="machine.mac" size={15} />
          <Icon name={home ? "placeholder" : "folder"} size={15} />
        </span>
        <span className="acpmux-thread-details__text">{home ? nt("noProject") : folderName(folder)}</span>
        {machine && <span className="acpmux-thread-details__meta">{machine}</span>}
      </div>
      {openIn && primary && (
        <div className="acpmux-thread-details__row acpmux-thread-details__split">
          <button type="button" className="acpmux-thread-details__main" onClick={() => open(primary)}>
            <AppIcon app={primary} />
            <span className="acpmux-thread-details__text">
              {t("preview.openIn")} {primary.name}
            </span>
          </button>
          {apps && apps.length > 1 && (
            <Menu>
              <MenuButton className="acpmux-thread-details__more" label={t("preview.openIn")}>
                <ChevronDown size={12} />
              </MenuButton>
              <MenuPopup align="end" className="acpmux-thread-details__menu">
                {apps.map((app) => (
                  <MenuItem key={app.id} className="acpmux-thread-details__item" onSelect={() => open(app)}>
                    <AppIcon app={app} />
                    {app.name}
                  </MenuItem>
                ))}
              </MenuPopup>
            </Menu>
          )}
        </div>
      )}
      {git?.branch && (
        <div className="acpmux-thread-details__row">
          <span className="acpmux-thread-details__icons" aria-hidden="true">
            <Icon name="git.branch" size={15} />
          </span>
          <span className="acpmux-thread-details__text">{git.branch}</span>
          {(away || (git.base && git.base !== git.branch)) && (
            <span className="acpmux-thread-details__meta">
              {[away, git.base && git.base !== git.branch ? git.base : ""].filter(Boolean).join(" · ")}
            </span>
          )}
        </div>
      )}
      {head && (
        <button
          type="button"
          className="acpmux-thread-details__row acpmux-thread-details__main"
          title={copied ? t("turn.copied") : t("turn.copy")}
          onClick={() =>
            void copyText(git!.head!).then(
              () => setCopied(true),
              () => setCopied(false),
            )
          }
        >
          <span className="acpmux-thread-details__icons" aria-hidden="true">
            <Icon name="action.copy" size={15} />
          </span>
          <span className="acpmux-thread-details__text acpmux-thread-details__commit">{head}</span>
          <span className="acpmux-thread-details__meta">{copied ? t("turn.copied") : t("git.commit.label")}</span>
        </button>
      )}
    </section>
  );
}
