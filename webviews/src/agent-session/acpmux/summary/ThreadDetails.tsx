// The top of Thread details (Lucas 2026-10-17, after T3 Code's thread menu): plain rows on the menu's
// rhythm. The machine the chat runs on (shared with the Environment rail); then Open in <app>: the
// folder in the app last picked (else the first editor installed), with that app's own icon, and a
// chevron for the others (`folder.openIn`). The project is the header's (header/ThreadTitle.tsx).
import { useEffect, useState } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { ChevronDown } from "../conversation/icons";
import { sessionMachine, type MachineSummary } from "./sessionMachine";

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
  summary,
  openIn,
}: {
  folder?: string;
  /// This Mac's name.
  machine?: string;
  summary?: MachineSummary;
  /// The host's Open in (`folder.openIn`): no app lists the apps; an app opens the folder there.
  openIn?: (app?: string) => Promise<OpenInApp[]>;
}) {
  const t = useT();
  const place = sessionMachine(summary, machine, t("composer.thisMac"));
  const [apps, setApps] = useState<OpenInApp[]>();
  const [preferred, setPreferred] = useState(readPreferred);
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
  const primary = apps?.find((app) => app.id === preferred) ?? apps?.find((app) => app.id !== "finder") ?? apps?.[0];
  const open = (app: OpenInApp) => {
    writePreferred(app.id);
    setPreferred(app.id);
    void openIn?.(app.id).catch(() => undefined);
  };
  return (
    <section className="acpmux-thread-details" aria-label={t("summary.threadDetails")}>
      <div className="acpmux-thread-details__row">
        <span className="acpmux-thread-details__icons" aria-hidden="true">
          <Icon name={place.icon} size={14} row className="ui-ghost-icon" />
        </span>
        <span className="acpmux-thread-details__text">{place.name}</span>
      </div>
      {openIn && primary && (
        <div className="acpmux-thread-details__row acpmux-thread-details__split">
          <button type="button" className="acpmux-thread-details__main" onClick={() => open(primary)}>
            <AppIcon app={primary} />
            <span className="acpmux-thread-details__text">{t("summary.openInApp", { app: primary.name })}</span>
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
    </section>
  );
}
