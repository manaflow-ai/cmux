// The Share dialog (design chat-multiplayer.md 2, "Share dialog"; Leo, 2026-11-07: "like being able
// to share Google Docs"): add people by email or @handle with a role, the people with access and
// their roles, General access (Restricted, or Anyone with the link as a viewer), Copy link and Done.
// Render only: every step is a prop the control (ShareControl.tsx) runs against the daemon, and
// the dialog never reads the host itself, so the gallery draws each state from a fixture.
import { useState, type FormEvent } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Select } from "../../../ui/Select";
import { useT } from "../i18n";
import { Face } from "../multiplayer/Faces";
import { Icon } from "../icons/Icon";
import { isAccount, type GeneralAccess, type SharePerson, type ShareRole, type ShareView } from "./shareState";
import "./share.css";

export interface ShareDialogProps {
  /** The chat's title. */
  chat: string;
  view: ShareView;
  /** Why the last step did not finish; null when it did. */
  status?: string | null;
  /** A step runs: the controls that start one wait. */
  busy?: boolean;
  onInvite(account: string, role: ShareRole): void;
  onRole(account: string, role: ShareRole): void;
  onRemove(account: string): void;
  onGeneral(access: GeneralAccess): void;
  onCopy(): void;
  onDone(): void;
}

const person = (account: string) => ({ id: `account:${account}`, name: account.replace(/^@/, "") });

export function ShareDialogBody({
  chat,
  view,
  status = null,
  busy = false,
  onInvite,
  onRole,
  onRemove,
  onGeneral,
  onCopy,
  onDone,
}: ShareDialogProps) {
  const t = useT();
  const [account, setAccount] = useState("");
  const [role, setRole] = useState<ShareRole>("view");
  const roles = [
    { value: "view", label: t("share.role.view") },
    { value: "talk", label: t("share.role.talk") },
  ];
  const canInvite = !busy && isAccount(account);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!canInvite) return;
    onInvite(account.trim(), role);
    setAccount("");
  };
  const canCopy = view.general === "anyone" || view.inviteUrl !== null;
  return (
    <div className="share-dialog">
      <h2 className="share-dialog__title">{t("share.title", { chat })}</h2>
      <form className="share-dialog__add" onSubmit={submit}>
        <Input
          className="share-dialog__field"
          value={account}
          placeholder={t("share.addPeople")}
          aria-label={t("share.addPeople")}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => setAccount(event.currentTarget.value)}
        />
        <Select
          className="share-dialog__role"
          buttonClassName="ui-btn"
          label={t("share.roleFor")}
          value={role}
          options={roles}
          closeOnPick
          align="end"
          onChange={(value) => setRole(value as ShareRole)}
        />
        <Button type="submit" disabled={!canInvite}>
          {t("share.invite")}
        </Button>
      </form>
      <p className="share-dialog__status" role={status ? "alert" : undefined}>
        {status ?? ""}
      </p>
      <section className="share-dialog__section" aria-label={t("share.peopleWithAccess")}>
        <h3 className="share-dialog__heading">{t("share.peopleWithAccess")}</h3>
        <ul className="share-dialog__people">
          <li className="share-dialog__person">
            <Face person={{ id: "me", name: t("share.you") }} size={28} />
            <span className="share-dialog__who">
              <span className="share-dialog__name">{t("share.you")}</span>
            </span>
            <span className="share-dialog__fixed-role">{t("share.owner")}</span>
          </li>
          {view.people.map((row) => (
            <PersonRow key={row.account} row={row} busy={busy} roles={roles} onRole={onRole} onRemove={onRemove} />
          ))}
        </ul>
      </section>
      <section className="share-dialog__section" aria-label={t("share.general")}>
        <h3 className="share-dialog__heading">{t("share.general")}</h3>
        <div className="share-dialog__general">
          <span className="share-dialog__general-mark" data-access={view.general} aria-hidden="true">
            <Icon name={view.general === "anyone" ? "link.web" : "security.lock"} size={16} />
          </span>
          <span className="share-dialog__who">
            <Select
              className="share-dialog__access"
              buttonClassName="ui-btn"
              label={t("share.general")}
              value={view.general}
              disabled={busy}
              closeOnPick
              options={[
                { value: "restricted", label: t("share.restricted") },
                { value: "anyone", label: t("share.anyone") },
              ]}
              onChange={(value) => onGeneral(value as GeneralAccess)}
            />
            <span className="share-dialog__hint">
              {view.general === "anyone" ? t("share.anyoneHint") : t("share.restrictedHint")}
            </span>
          </span>
          {view.general === "anyone" && <span className="share-dialog__fixed-role">{t("share.role.view")}</span>}
        </div>
      </section>
      <footer className="share-dialog__footer">
        <Button variant="subtle" disabled={busy || !canCopy} onClick={onCopy}>
          {t("share.copyLink")}
        </Button>
        <Button variant="solid" onClick={onDone}>
          {t("share.done")}
        </Button>
      </footer>
    </div>
  );
}

function PersonRow({
  row,
  busy,
  roles,
  onRole,
  onRemove,
}: {
  row: SharePerson;
  busy: boolean;
  roles: { value: string; label: string }[];
  onRole(account: string, role: ShareRole): void;
  onRemove(account: string): void;
}) {
  const t = useT();
  return (
    <li className="share-dialog__person">
      <Face person={person(row.account)} size={28} />
      <span className="share-dialog__who">
        <span className="share-dialog__name" title={row.account}>
          {row.account}
        </span>
        {row.joined && <span className="share-dialog__hint">{t("share.inChatNow")}</span>}
      </span>
      <Select
        className="share-dialog__role"
        buttonClassName="ui-btn"
        label={t("share.roleOf", { account: row.account })}
        value={row.role}
        disabled={busy}
        closeOnPick
        align="end"
        options={roles}
        onChange={(value) => value !== row.role && onRole(row.account, value as ShareRole)}
      />
      <Button variant="ghost" danger disabled={busy} onClick={() => onRemove(row.account)}>
        {t("share.remove")}
      </Button>
    </li>
  );
}
