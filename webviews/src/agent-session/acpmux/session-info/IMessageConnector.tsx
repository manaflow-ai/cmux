import { memo } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { imessageError, type IMessageView } from "./imessage";
import "./imessage.css";

export type IMessageLook = "list" | "grouped" | "details";

export const IMessageConnector = memo(function IMessageConnector({
  view,
  look = "list",
}: {
  view: IMessageView;
  look?: IMessageLook;
}) {
  const t = useT();
  const { data, busy, expanded, perform, toggle } = view;
  const connected = data.status === "connected";
  const button = (action: Parameters<typeof perform>[0], label: string) => (
    <button type="button" className="acpmux-session-info-link" disabled={busy} onClick={() => void perform(action)}>
      {label}
    </button>
  );
  const threads =
    look === "grouped"
      ? [...data.threads.filter((thread) => !thread.is_group), ...data.threads.filter((thread) => thread.is_group)]
      : data.threads;
  return (
    <li className="acpmux-imessage" data-status={data.status} data-look={look}>
      <div className="acpmux-session-info-row">
        <Icon name="agent.chat" size={rowIconSize(12)} row />
        {/* l10n-allow: iMessage is Apple's invariant product name. */}
        <span className="acpmux-session-info-row__name">iMessage</span>
        {connected ? (
          <button
            type="button"
            className="acpmux-session-info-link acpmux-session-info-row__end"
            aria-expanded={expanded}
            onClick={toggle}
            disabled={busy}
          >
            {t("composer.envConnected")}
          </button>
        ) : data.status === "not_connected" ? (
          <span className="acpmux-session-info-row__end">{button("connect", t("imessage.connect"))}</span>
        ) : (
          <span className="acpmux-session-info-row__end">{t("imessage.setup")}</span>
        )}
      </div>
      {data.error && (
        <p className="acpmux-imessage-copy" role="alert">
          {imessageError(data.error, t)}
        </p>
      )}
      {data.status === "needs_full_disk_access" && (
        <div className="acpmux-imessage-body">
          <p className="acpmux-imessage-copy">{t("imessage.diskHelp")}</p>
          <div className="acpmux-imessage-actions">
            {button("full_disk_access", t("imessage.grantDisk"))}
            {button("disconnect", t("permission.feedbackCancel"))}
          </div>
        </div>
      )}
      {data.status === "needs_automation" && (
        <div className="acpmux-imessage-body">
          <p className="acpmux-imessage-copy">{t("imessage.automationHelp")}</p>
          <div className="acpmux-imessage-actions">
            {button("automation", t("imessage.allowMessages"))}
            {button("skip_automation", t("question.skip"))}
            {button("disconnect", t("permission.feedbackCancel"))}
          </div>
        </div>
      )}
      {connected && expanded && (
        <div className="acpmux-imessage-body">
          <p className="acpmux-imessage-copy">{t("imessage.sendClick")}</p>
          {!data.sends_enabled && <p className="acpmux-imessage-copy">{t("imessage.automationHelp")}</p>}
          <p className="acpmux-imessage-heading">{t("imessage.contactsGroups")}</p>
          <ul className="acpmux-session-info-list">
            {threads.map((thread) => (
              <li key={thread.chat_id} className="acpmux-imessage-thread" title={thread.participants.join(", ")}>
                <Icon
                  name={thread.is_group ? "agent.chat.list" : "browser.toolbar.profile"}
                  size={rowIconSize(12)}
                  row
                />
                <span>
                  <span className="acpmux-imessage-thread-name">{thread.title || thread.participants.join(", ")}</span>
                  {look === "details" && thread.is_group && (
                    <span className="acpmux-imessage-copy">{thread.participants.join(", ")}</span>
                  )}
                </span>
              </li>
            ))}
          </ul>
          {!busy && !data.error && threads.length === 0 && (
            <p className="acpmux-imessage-copy">{t("imessage.noThreads")}</p>
          )}
          <div className="acpmux-imessage-actions">
            {!data.sends_enabled && button("automation", t("imessage.allowMessages"))}
            {data.error && button("threads", t("sessionInfo.connectors.retry"))}
            {button("disconnect", t("imessage.disconnect"))}
          </div>
        </div>
      )}
    </li>
  );
});
