// Page Info's On-device site data window: every site that stored cookies or other data while the
// page was open, each with a delete button, and Done. The web twin of the native SiteDataWindow; the
// host (PageInfoWindows) deletes and pushes the new list.
import type { FormEvent } from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import type { Strings } from "../../pages/shared/i18n";
import { Button } from "../../ui/Button";
import { DialogButton } from "../../ui/DialogButton";
import { WindowFrame, WindowRow } from "./PageInfoWindowParts";
import { pageInfoStrings } from "./strings";
import type { PageInfoWindowCommand, SiteDataEntry, SiteDataState } from "./windows";

/**
 * - `parity`: today's native list (each site says whether it is this site or a third party).
 * - `grouped`: this site and third parties under their own headings.
 * - `compact`: one line per site, its details trailing.
 */
export type SiteDataLook = "parity" | "grouped" | "compact";

export type SiteDataWindowProps = {
  state: SiteDataState;
  onCommand: (command: PageInfoWindowCommand) => void;
  look?: SiteDataLook;
  strings?: Strings;
};

/** A site's details: this site or third party (unless a heading says it), cookies, other data. */
export function siteDataDetails(strings: Strings, entry: SiteDataEntry, withParty: boolean): string {
  const details: string[] = [];
  if (withParty)
    details.push(strings.t(entry.isThirdParty ? "pageInfo.siteData.thirdParty" : "pageInfo.siteData.thisSite"));
  if (entry.cookieCount > 0) details.push(strings.format("pageInfo.siteData.cookies", String(entry.cookieCount)));
  if (entry.hasOtherData) details.push(strings.t("pageInfo.siteData.otherData"));
  return details.join(" · ");
}

function Entries({
  entries,
  withParty,
  strings,
  send,
}: {
  entries: SiteDataEntry[];
  withParty: boolean;
  strings: Strings;
  send: (command: PageInfoWindowCommand) => void;
}) {
  return (
    <ul className="piw-list">
      {entries.map((entry) => {
        const label = strings.format("pageInfo.siteData.deleteFor", entry.domain);
        return (
          <WindowRow
            key={entry.domain}
            id={`pageInfo.siteData.${entry.domain}`}
            icon="link.web"
            title={entry.domain}
            subtitle={siteDataDetails(strings, entry, withParty) || undefined}
            trailing={
              <Button
                icon
                size="sm"
                variant="ghost"
                aria-label={label}
                title={label}
                onClick={() => send({ type: "deleteSiteData", domain: entry.domain })}
              >
                <Icon name="action.delete" size={14} row />
              </Button>
            }
          />
        );
      })}
    </ul>
  );
}

export function SiteDataWindow({
  state,
  onCommand,
  look = "parity",
  strings = pageInfoStrings(),
}: SiteDataWindowProps) {
  const t = strings.t;
  const close = () => onCommand({ type: "close" });
  const done = (event: FormEvent) => {
    event.preventDefault();
    close();
  };
  const entries = state.entries;
  const firstParty = entries?.filter((entry) => !entry.isThirdParty) ?? [];
  const thirdParty = entries?.filter((entry) => entry.isThirdParty) ?? [];
  return (
    <WindowFrame look={look} label={t("pageInfo.siteData.subtitle")} onClose={close} onReturn={close}>
      <form className="piw-section" onSubmit={done}>
        <p className="piw-muted">{t("pageInfo.siteData.subtitle")}</p>
        {!entries && <p className="piw-muted">{t("pageInfo.loading")}</p>}
        {entries?.length === 0 && <p className="piw-muted">{t("pageInfo.siteData.empty")}</p>}
        {entries && entries.length > 0 && look !== "grouped" && (
          <Entries entries={entries} withParty strings={strings} send={onCommand} />
        )}
        {look === "grouped" &&
          [
            { id: "thisSite", title: t("pageInfo.siteData.thisSite"), list: firstParty },
            { id: "thirdParty", title: t("pageInfo.siteData.thirdParty"), list: thirdParty },
          ]
            .filter((group) => group.list.length > 0)
            .map((group) => (
              <div key={group.id} className="piw-list">
                <h2 className="piw-title">{group.title}</h2>
                <Entries entries={group.list} withParty={false} strings={strings} send={onCommand} />
              </div>
            ))}
        <div className="piw-footer">
          <DialogButton dialogKey="return" type="submit" className="ui-btn" data-variant="solid" data-size="md">
            {t("pageInfo.done")}
          </DialogButton>
        </div>
      </form>
    </WindowFrame>
  );
}
