// The sheet the page's route names (routes.ts), drawn over the page. A route whose capability is
// missing (an older cmux instance, a plain browser for an archive) shows why and how, never a
// form that cannot work. Archive asks once, in the person's words: the Chief stops, leaves the
// list, and its memory is kept for 30 days. New Chief and Edit Chief are no sheet: they are a
// page on Home's right side (ChiefRoutePage, ChiefPage.tsx).
import { useState } from "react";
import type { Strings } from "../shared/i18n";
import { ChiefPage } from "./ChiefPage";
import { InviteSheet, NewMessageSheet } from "./ConversationSheets";
import { FormDialog } from "./FormDialog";
import { conversationName } from "./model";
import type { HomeSheets, SheetsSnapshot } from "./sheets";
import type { HomeChief, HomeConversation } from "./types";

export function RouteSheets({
  sheets,
  state,
  strings,
  conversations,
  me,
}: {
  sheets: HomeSheets;
  state: SheetsSnapshot;
  strings: Strings;
  conversations: ReadonlyMap<string, HomeConversation>;
  me?: string;
}) {
  const route = state.route;
  if (!route || !state.ready) return null;
  const caps = state.capabilities;
  switch (route.kind) {
    case "newMessage":
      return caps.start ? (
        <NewMessageSheet sheets={sheets} strings={strings} />
      ) : (
        <Notice sheets={sheets} strings={strings} />
      );
    case "invite": {
      const conversation = conversations.get(route.conversation);
      if (!caps.invite || !conversation || conversation.owner !== "local")
        return <Notice sheets={sheets} strings={strings} />;
      return (
        <InviteSheet
          sheets={sheets}
          strings={strings}
          conversation={conversation.id}
          name={conversationName(conversation, me)}
          members={conversation.participants.map((p) => p.id)}
        />
      );
    }
    case "newChief":
    case "editChief":
      // A page, not a sheet: HomeChannelsPage draws ChiefRoutePage in its right side.
      return null;
    case "archiveChief": {
      const chief = state.chiefs.get(route.chief);
      if (!caps.chiefs) return <Notice sheets={sheets} strings={strings} />;
      if (!chief) return <Notice sheets={sheets} strings={strings} body={strings.t("sheet.chiefMissing")} />;
      if (chief.isDefault)
        return <Notice sheets={sheets} strings={strings} body={strings.t("sheet.archive.default")} />;
      if (!state.chiefGrants)
        return <Notice sheets={sheets} strings={strings} body={strings.t("sheet.archive.appOnly")} />;
      return <ArchiveChiefSheet sheets={sheets} strings={strings} chief={chief} />;
    }
  }
}

/** New Chief and Edit Chief as a page in Home's right side (u2586), or why it cannot show. */
export function ChiefRoutePage({
  sheets,
  state,
  strings,
}: {
  sheets: HomeSheets;
  state: SheetsSnapshot;
  strings: Strings;
}) {
  const { t } = strings;
  const route = state.route;
  if (!route || (route.kind !== "newChief" && route.kind !== "editChief") || !state.ready) return null;
  const chief = route.kind === "editChief" ? state.chiefs.get(route.chief) : undefined;
  const reason = !state.capabilities.chiefs
    ? t("sheet.unavailable.body")
    : route.kind === "editChief" && !chief
      ? t("sheet.chiefMissing")
      : undefined;
  if (reason)
    return (
      <div className="lg-empty" data-chief-page="unavailable">
        <h1 className="lg-empty-title">{t("sheet.unavailable.title")}</h1>
        <p className="lg-empty-body">{reason}</p>
        <div className="lg-empty-actions">
          <button type="button" className="lg-button" onClick={() => sheets.close()}>
            {t("sheet.close")}
          </button>
        </div>
      </div>
    );
  return (
    <ChiefPage
      key={chief?.id ?? "new"}
      service={sheets.chiefEditor()}
      strings={strings}
      chief={chief}
      picture={chief ? state.pictures.get(chief.id) : undefined}
      chiefName={(id) => state.chiefs.get(id)?.name}
    />
  );
}

function ArchiveChiefSheet({ sheets, strings, chief }: { sheets: HomeSheets; strings: Strings; chief: HomeChief }) {
  const { t, format } = strings;
  const [busy, setBusy] = useState(false);
  const archive = () => {
    setBusy(true);
    void sheets.archiveChief(chief.id).finally(() => setBusy(false));
  };
  return (
    <FormDialog
      title={format("sheet.archive.title", chief.name)}
      lead={t("sheet.archive.lead")}
      onClose={() => sheets.close()}
      onSubmit={archive}
      busy={busy}
      actions={
        <>
          <button type="button" className="hc-text-button" onClick={() => sheets.close()}>
            {t("edit.cancel")}
          </button>
          <button type="submit" className="hc-text-button danger" disabled={busy}>
            {t("sheet.archive.confirm")}
          </button>
        </>
      }
    />
  );
}

/** A route this connection cannot serve: why, and Close. */
function Notice({ sheets, strings, body }: { sheets: HomeSheets; strings: Strings; body?: string }) {
  const { t } = strings;
  return (
    <FormDialog
      title={t("sheet.unavailable.title")}
      lead={body ?? t("sheet.unavailable.body")}
      onClose={() => sheets.close()}
      onSubmit={() => sheets.close()}
      actions={
        <button type="submit" className="hc-text-button primary">
          {t("sheet.close")}
        </button>
      }
    />
  );
}
