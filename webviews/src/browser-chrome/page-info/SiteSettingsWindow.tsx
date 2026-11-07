// Page Info's Site settings window for one origin (like `chrome://settings/content/siteDetails`):
// its usage with Delete data, every permission this engine can enforce with its choices, and Reset
// permissions. The web twin of the native SiteSettingsWindow; it draws the host's state and sends
// `PageInfoWindowCommand`s, and the host (PageInfoWindows) owns the window and the store.
import type { Strings } from "../../pages/shared/i18n";
import { Button } from "../../ui/Button";
import { Select } from "../../ui/Select";
import { permissionIcon, type SitePermissionSetting } from "./model";
import { WindowFrame, WindowRow } from "./PageInfoWindowParts";
import { pageInfoStrings } from "./strings";
import type { PageInfoWindowCommand, SiteSettingsPermission, SiteSettingsState } from "./windows";
import { choiceTitle, permissionName } from "./words";

/**
 * - `parity`: today's native window (titled sections, a value menu per permission).
 * - `grouped`: each section on its own inset card, hairlines between permissions.
 * - `segmented`: every choice shown on the row as a segmented control, no menu to open.
 */
export type SiteSettingsLook = "parity" | "grouped" | "segmented";

export type SiteSettingsWindowProps = {
  state: SiteSettingsState;
  onCommand: (command: PageInfoWindowCommand) => void;
  look?: SiteSettingsLook;
  strings?: Strings;
};

/** The usage line: "Cookies from this site: N · Sites with data: N", or Loading. */
export function usageText(strings: Strings, usage: SiteSettingsState["usage"]): string {
  if (!usage) return strings.t("pageInfo.loading");
  return [
    strings.format("pageInfo.cookies.count", String(usage.firstPartyCookies)),
    strings.format("pageInfo.cookies.sites", String(usage.siteCount)),
  ].join(" · ");
}

function PermissionControl({
  row,
  look,
  strings,
  send,
}: {
  row: SiteSettingsPermission;
  look: SiteSettingsLook;
  strings: Strings;
  send: (command: PageInfoWindowCommand) => void;
}) {
  const name = permissionName(strings, row.kind);
  const pick = (setting: SitePermissionSetting) => send({ type: "setPermission", kind: row.kind, setting });
  if (look === "segmented") {
    return (
      <span className="piw-segments" role="group" aria-label={name}>
        {row.choices.map((choice) => (
          <Button
            key={choice}
            size="sm"
            variant="ghost"
            aria-pressed={choice === row.setting}
            onClick={() => choice !== row.setting && pick(choice)}
          >
            {choiceTitle(strings, choice, row.kind)}
          </Button>
        ))}
      </span>
    );
  }
  return (
    <Select
      value={row.setting}
      label={name}
      closeOnPick
      align="end"
      options={row.choices.map((choice) => ({ value: choice, label: choiceTitle(strings, choice, row.kind) }))}
      onChange={(value) => value !== row.setting && pick(value as SitePermissionSetting)}
    />
  );
}

export function SiteSettingsWindow({
  state,
  onCommand,
  look = "parity",
  strings = pageInfoStrings(),
}: SiteSettingsWindowProps) {
  const t = strings.t;
  return (
    <WindowFrame look={look} label={state.site.displayName} onClose={() => onCommand({ type: "close" })}>
      <div className="piw-section">
        <h2 className="piw-title">{t("pageInfo.siteSettings.usage")}</h2>
        <p className="piw-muted">{usageText(strings, state.usage)}</p>
        <Button size="sm" onClick={() => onCommand({ type: "deleteSiteData" })}>
          {t("pageInfo.siteSettings.deleteData")}
        </Button>
      </div>
      <div className="piw-section piw-permissions">
        <h2 className="piw-title">{t("pageInfo.siteSettings.permissions")}</h2>
        <ul className="piw-list" data-divided={look === "grouped" || undefined}>
          {state.permissions.map((row) => (
            <WindowRow
              key={row.kind}
              id={`pageInfo.siteSettings.${row.kind}`}
              icon={permissionIcon(row.kind, false)}
              title={permissionName(strings, row.kind)}
              trailing={<PermissionControl row={row} look={look} strings={strings} send={onCommand} />}
            />
          ))}
        </ul>
        <Button size="sm" disabled={!state.canReset} onClick={() => onCommand({ type: "resetPermissions" })}>
          {t("pageInfo.reset.many")}
        </Button>
        <p className="piw-caption">{t("pageInfo.siteSettings.engineLimited")}</p>
      </div>
    </WindowFrame>
  );
}
