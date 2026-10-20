// The sheet the page's route names (routes.ts), drawn over the page. A route whose capability is
// missing (an older cmux instance, a plain browser for an archive) shows why and how, never a
// form that cannot work. Archive asks once, in the person's words: the Chief stops, leaves the
// list, and its memory is kept for 30 days.
import { useState } from "react";
import type { Strings } from "../shared/i18n";
import { ChiefSheet } from "./ChiefSheet";
import { InviteSheet, NewMessageSheet } from "./ConversationSheets";
import { DialogButton } from "../../ui/DialogButton";
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
      return caps.chiefs ? (
        <ChiefSheet sheets={sheets} strings={strings} grants={state.chiefGrants} />
      ) : (
        <Notice sheets={sheets} strings={strings} />
      );
    case "editChief": {
      const chief = state.chiefs.get(route.chief);
      if (!caps.chiefs) return <Notice sheets={sheets} strings={strings} />;
      if (!chief) return <Notice sheets={sheets} strings={strings} body={strings.t("sheet.chiefMissing")} />;
      return (
        <ChiefSheet
          key={chief.id}
          sheets={sheets}
          strings={strings}
          chief={chief}
          picture={state.pictures.get(chief.id)}
          grants={state.chiefGrants}
        />
      );
    }
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
          <DialogButton dialogKey="escape" className="hc-text-button" onClick={() => sheets.close()}>
            {t("edit.cancel")}
          </DialogButton>
          <DialogButton dialogKey="return" type="submit" className="hc-text-button danger" disabled={busy}>
            {t("sheet.archive.confirm")}
          </DialogButton>
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
        <DialogButton dialogKey="return" type="submit" className="hc-text-button primary">
          {t("sheet.close")}
        </DialogButton>
      }
    />
  );
}
