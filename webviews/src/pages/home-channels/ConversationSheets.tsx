// The conversation sheets: a new message (#/new/message) and adding people (#/conversation/<id>/
// invite). Both pick from the directory (people met so far and the Chiefs). A new message with one
// pick and no name opens my existing direct message with them, or makes it; a name or several
// picks make a channel. The owner checks every rule; a refusal shows on the page.
import { useEffect, useState } from "react";
import type { Strings } from "../shared/i18n";
import { DialogButton } from "../../ui/DialogButton";
import { FormDialog } from "./FormDialog";
import { PeoplePicker } from "./PeoplePicker";
import type { HomeSheets } from "./sheets";
import type { HomeParticipant } from "./types";

/** The directory, read once when a sheet opens. */
function useDirectory(sheets: HomeSheets, exclude: readonly string[] = []) {
  const [people, setPeople] = useState<HomeParticipant[] | undefined>();
  const key = exclude.join();
  useEffect(() => {
    let live = true;
    void sheets.directory().then((found) => {
      if (live) setPeople(found.filter((person) => !exclude.includes(person.id)));
    });
    return () => {
      live = false;
    };
    // `exclude` is read through its key.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [sheets, key]);
  return people;
}

export function NewMessageSheet({ sheets, strings }: { sheets: HomeSheets; strings: Strings }) {
  const { t } = strings;
  const people = useDirectory(sheets);
  const [picked, setPicked] = useState<string[]>([]);
  const [title, setTitle] = useState("");
  const [busy, setBusy] = useState(false);
  const channel = title.trim() !== "" || picked.length > 1;
  const ready = picked.length > 0 && !busy;
  const submit = () => {
    if (!ready) return;
    setBusy(true);
    void sheets.startConversation(picked, title).finally(() => setBusy(false));
  };
  return (
    <FormDialog
      title={t("sheet.newMessage.title")}
      lead={t("sheet.newMessage.lead")}
      onClose={() => sheets.close()}
      onSubmit={submit}
      busy={busy}
      actions={
        <>
          <DialogButton dialogKey="escape" className="hc-text-button" onClick={() => sheets.close()}>
            {t("edit.cancel")}
          </DialogButton>
          <DialogButton dialogKey="return" type="submit" className="hc-text-button primary" disabled={!ready}>
            {t(channel ? "channel.create" : "sheet.open")}
          </DialogButton>
        </>
      }
    >
      <PeoplePicker
        people={people ?? []}
        loading={people === undefined}
        picked={picked}
        onPicked={setPicked}
        strings={strings}
      />
      <label className="lg-form-field">
        <span className="lg-form-label">{t("sheet.channelName")}</span>
        <input
          className="hc-link-field"
          aria-label={t("sheet.channelName")}
          value={title}
          maxLength={80}
          placeholder={t("channel.namePlaceholder")}
          onChange={(event) => setTitle(event.target.value)}
        />
      </label>
    </FormDialog>
  );
}

export function InviteSheet({
  sheets,
  strings,
  conversation,
  name,
  members,
}: {
  sheets: HomeSheets;
  strings: Strings;
  conversation: string;
  /** The conversation's name as the page shows it. */
  name: string;
  /** Who is in it already (not offered). */
  members: readonly string[];
}) {
  const { t, format } = strings;
  const people = useDirectory(sheets, members);
  const [picked, setPicked] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const ready = picked.length > 0 && !busy;
  const submit = () => {
    if (!ready) return;
    setBusy(true);
    void sheets.invite(conversation, picked).finally(() => setBusy(false));
  };
  return (
    <FormDialog
      title={format("sheet.invite.title", name)}
      lead={t("sheet.invite.lead")}
      onClose={() => sheets.close()}
      onSubmit={submit}
      busy={busy}
      actions={
        <>
          <DialogButton dialogKey="escape" className="hc-text-button" onClick={() => sheets.close()}>
            {t("edit.cancel")}
          </DialogButton>
          <DialogButton dialogKey="return" type="submit" className="hc-text-button primary" disabled={!ready}>
            {t("sheet.invite.add")}
          </DialogButton>
        </>
      }
    >
      <PeoplePicker
        people={people ?? []}
        loading={people === undefined}
        picked={picked}
        onPicked={setPicked}
        strings={strings}
      />
    </FormDialog>
  );
}
