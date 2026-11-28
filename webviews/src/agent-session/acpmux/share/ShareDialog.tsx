// The Share dialog (design chat-multiplayer.md 2, "Share dialog"; Leo, 2026-11-07: "like being able
// to share Google Docs"): add people by email or @handle with a role, the people with access and
// their roles, the accounts asking for access (Approve with a role, or Decline; RFD 0077 D5), General access (Restricted, or Anyone with the link: signed-in people may send, others watch), Copy link and Done.
// Render only: every step is a prop the control (ShareControl.tsx) runs against the daemon, and
// the dialog never reads the host itself, so the gallery draws each state from a fixture.
import { useState, type FormEvent, type ReactNode } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../../ui/Menu";
import { Select } from "../../../ui/Select";
import { useT } from "../i18n";
import { Face } from "../multiplayer/Faces";
import { Icon } from "../icons/Icon";
import {
  isAccount,
  type GeneralAccess,
  type SharePerson,
  type ShareRole,
  type ShareView,
  type ShareAccessRequest,
} from "./shareState";
import { ShareTeams } from "./ShareTeams";
import "./share.css";

export interface ShareDialogProps {
  /** The chat's title. */
  chat: string;
  view: ShareView;
  /** Why the last step did not finish; null when it did. */
  status?: string | null;
  /// A result that is not a refusal ("…changed to Can send"): the status line, muted.
  notice?: string | null;
  /** A step runs: the controls that start one wait. */
  busy?: boolean;
  onInvite(account: string, role: ShareRole): void;
  onRole(account: string, role: ShareRole): void;
  onRemove(account: string): void;
  /** Approve an access request: the account gets `role` (the row's picker starts at Can view). */
  onApprove(account: string, role: ShareRole): void;
  /** Decline an access request: silent, the account is not told. */
  onDecline(account: string): void;
  onGeneral(access: GeneralAccess): void;
  onTeam?(teamId: string, role: ShareRole): void;
  onTeamRemove?(shareId: string): void;
  onTeamCopy?(url: string): void;
  onCopy(): void;
  onDone(): void;
}

const person = (account: string) => ({ id: `account:${account}`, name: account.replace(/^@/, "") });

export function ShareDialogBody({
  chat,
  view,
  status = null,
  notice = null,
  busy = false,
  onInvite,
  onRole,
  onRemove,
  onApprove,
  onDecline,
  onGeneral,
  onTeam,
  onTeamRemove,
  onTeamCopy,
  onCopy,
  onDone,
}: ShareDialogProps) {
  const t = useT();
  const [account, setAccount] = useState("");
  const [role, setRole] = useState<ShareRole>("view");
  const roles = [
    { value: "view", label: t("share.role.view") },
    { value: "talk", label: t("share.role.talk") },
    { value: "drive", label: t("share.role.drive") },
  ];
  /** The role each request row's picker shows (absent: Can view, the least). */
  const [asked, setAsked] = useState<Record<string, ShareRole>>({});
  const askedRole = (who: string): ShareRole => asked[who] ?? "view";
  const askedTalk = view.requests.some((request) => askedRole(request.account) === "talk");
  const canInvite = !busy && isAccount(account);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!canInvite) return;
    onInvite(account.trim(), role);
    setAccount("");
    if (role === "drive") setRole("view");
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
          onChange={(event) => {
            setAccount(event.currentTarget.value);
            if (role === "drive") setRole("view");
          }}
        />
        <Select
          className="share-dialog__role"
          buttonClassName="ui-btn"
          label={t("share.roleFor")}
          value={role}
          options={isAccount(account) ? roles : roles.filter((option) => option.value !== "drive")}
          closeOnPick
          align="end"
          onChange={(value) => setRole(value as ShareRole)}
        />
        <Button type="submit" disabled={!canInvite}>
          {t("share.invite")}
        </Button>
      </form>
      {/* One fixed line under the field: a refusal or a result when there is one, else what "Can
          send" means (each message waits for the owner), so the label stays short. */}
      <p className="share-dialog__status" role={status ? "alert" : undefined} data-hint={status ? undefined : ""}>
        {status ??
          notice ??
          (role === "drive"
            ? t("share.role.driveDetail")
            : role === "talk" || askedTalk
              ? t("share.role.talkHint")
              : "")}
      </p>
      {/* Accounts asking for access, above the people who have it: a band of at most two rows that
          scrolls past them, and the people band gives up the same room (share.css), so the dialog
          keeps one height. No requests: no band. */}
      {view.requests.length > 0 && (
        <section
          className="share-dialog__section share-dialog__requests"
          aria-label={t("share.requests")}
          data-rows={Math.min(view.requests.length, 2)}
        >
          <h3 className="share-dialog__heading share-dialog__requests-heading">
            {t("share.requests")}
            {view.requests.length > 2 && <span className="share-dialog__count">{view.requests.length}</span>}
          </h3>
          <ul className="share-dialog__asks">
            {view.requests.map((request) => (
              <RequestRow
                key={request.account}
                request={request}
                role={askedRole(request.account)}
                busy={busy}
                roles={roles.filter((option) => option.value !== "drive")}
                onRole={(next) => setAsked((was) => ({ ...was, [request.account]: next }))}
                onApprove={onApprove}
                onDecline={onDecline}
              />
            ))}
          </ul>
        </section>
      )}
      <section
        className="share-dialog__section"
        aria-label={t("share.peopleWithAccess")}
        data-asks={Math.min(view.requests.length, 2)}
      >
        <h3 className="share-dialog__heading">{t("share.peopleWithAccess")}</h3>
        <ul className="share-dialog__people">
          <li className="share-dialog__person share-dialog__person--owner">
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
        {/* The whole block is the picker (Leo, 2026-11-07: "if you have these big blocks you need to
            have the blocks be clickable"): Restricted turns a link back off (shareState.ts restrict). */}
        <RowPicker
          className="share-dialog__general"
          value={view.general}
          disabled={busy}
          align="start"
          options={[
            { value: "restricted", label: t("share.restricted") },
            { value: "anyone", label: t("share.anyone") },
          ]}
          onChange={(value) => value !== view.general && onGeneral(value as GeneralAccess)}
        >
          <span className="share-dialog__general-mark" data-access={view.general} aria-hidden="true">
            <Icon name={view.general === "anyone" ? "link.web" : "security.lock"} size={16} />
          </span>
          <span className="share-dialog__who">
            <span className="share-dialog__name">
              {view.general === "anyone" ? t("share.anyone") : t("share.restricted")}
            </span>
            <span className="share-dialog__hint">
              {view.general === "anyone" ? t("share.anyoneHint") : t("share.restrictedHint")}
            </span>
          </span>
          {/* A signed-in guest on the link may send (cmux#38102), so the row names the People rows'
              "Can send"; the hint says a guest nobody signed in only watches. */}
          {view.general === "anyone" && <span className="share-dialog__fixed-role">{t("share.role.talk")}</span>}
        </RowPicker>
      </section>
      <ShareTeams view={view} busy={busy} onTeam={onTeam} onRemove={onTeamRemove} onCopy={onTeamCopy} />
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
      <RowPicker
        className="share-dialog__person-pick"
        value={row.role}
        disabled={busy}
        align="end"
        options={roles.map((option) =>
          option.value === "drive" ? { ...option, detail: t("share.role.driveDetail") } : option,
        )}
        onChange={(value) => value !== row.role && onRole(row.account, value as ShareRole)}
      >
        <Face person={person(row.account)} size={28} />
        <span className="share-dialog__who">
          <span className="share-dialog__name">{row.account}</span>
          {row.joined ? (
            <span className="share-dialog__hint">{t("share.inChatNow")}</span>
          ) : (
            row.opened === false && <span className="share-dialog__hint">{t("share.notJoined")}</span>
          )}
        </span>
        <span className="share-dialog__role-value">{roles.find((role) => role.value === row.role)?.label}</span>
      </RowPicker>
      {/* Narrow, the word gives way to an x (share.css); the label always names whom it removes. */}
      <Button
        className="share-dialog__remove"
        variant="ghost"
        danger
        disabled={busy}
        aria-label={t("share.removeWho", { account: row.account })}
        onClick={() => onRemove(row.account)}
      >
        <Icon name="action.close" className="share-dialog__remove-mark" />
        <span className="share-dialog__remove-word">{t("share.remove")}</span>
      </Button>
    </li>
  );
}

function RequestRow({
  request,
  role,
  busy,
  roles,
  onRole,
  onApprove,
  onDecline,
}: {
  request: ShareAccessRequest;
  role: ShareRole;
  busy: boolean;
  roles: { value: string; label: string }[];
  onRole(role: ShareRole): void;
  onApprove(account: string, role: ShareRole): void;
  onDecline(account: string): void;
}) {
  const t = useT();
  const name = request.name.trim();
  return (
    <li className="share-dialog__person share-dialog__ask">
      <Face
        person={{
          id: `account:${request.account}`,
          name: name || request.account,
          avatar: request.avatarUrl ?? undefined,
        }}
        size={28}
      />
      <span className="share-dialog__who">
        <span className="share-dialog__name">{name || request.account}</span>
        {name && <span className="share-dialog__hint">{request.account}</span>}
      </span>
      <Select
        className="share-dialog__role share-dialog__ask-role"
        buttonClassName="ui-btn"
        label={t("share.roleForWho", { account: request.account })}
        value={role}
        options={roles}
        closeOnPick
        align="end"
        disabled={busy}
        onChange={(value) => onRole(value as ShareRole)}
      />
      <Button disabled={busy} onClick={() => onApprove(request.account, role)}>
        {t("share.approve")}
      </Button>
      {/* Narrow, the word gives way to an x as Remove's does; the label always names whom. */}
      <Button
        className="share-dialog__remove"
        variant="ghost"
        disabled={busy}
        aria-label={t("share.declineWho", { account: request.account })}
        onClick={() => onDecline(request.account)}
      >
        <Icon name="action.close" className="share-dialog__remove-mark" />
        <span className="share-dialog__remove-word">{t("share.decline")}</span>
      </Button>
    </li>
  );
}

/** A big row that is one button: its press opens its choices (a select's menu), with
 * the hover and press fills on the whole row, as the account picker's rows are one target. */
function RowPicker({
  className,
  value,
  options,
  disabled,
  align,
  onChange,
  children,
}: {
  className: string;
  value: string;
  options: { value: string; label: string; detail?: string }[];
  disabled: boolean;
  align: "start" | "end";
  onChange(value: string): void;
  children: ReactNode;
}) {
  return (
    <Menu>
      <MenuButton className={`share-dialog__row ${className}`} disabled={disabled} aria-haspopup="menu">
        {children}
        <span className="share-dialog__chevron" aria-hidden="true" />
      </MenuButton>
      <MenuPopup className="ui-select-popup" align={align}>
        <MenuRadioGroup value={value} onValueChange={onChange}>
          {options.map((option) => (
            <MenuRadioItem key={option.value} value={option.value} closeOnClick className="ui-select-option">
              {option.detail ? (
                <span className="share-dialog__who">
                  <span>{option.label}</span>
                  <span className="share-dialog__hint">{option.detail}</span>
                </span>
              ) : (
                option.label
              )}
            </MenuRadioItem>
          ))}
        </MenuRadioGroup>
      </MenuPopup>
    </Menu>
  );
}
