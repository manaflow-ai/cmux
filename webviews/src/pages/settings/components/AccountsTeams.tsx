// Settings > Accounts, Teams: one row per team with your role, the open team's details (members,
// pending invitations for admins, plan), and the create, rename and delete forms. Like the rest of
// Accounts, the host sends every text and decides what each person may do (members get no Rename
// or Delete); the page draws it and forwards `team.*` gestures. A typed name lives in the form's
// own state until it is submitted.
import { useState, type KeyboardEvent } from "react";
import { useStore } from "../context";
import type { AccountsButton, AccountsTeamDetails, AccountsTeamForm, AccountsTeamList, AccountsTeamRow } from "../ops";

export function TeamsGroup({ list }: { list: AccountsTeamList }) {
  const store = useStore();
  return (
    <section className="group" data-accounts-team-list="">
      <h3 className="group-title">{list.title}</h3>
      <div className="accounts-header">
        <TeamButton button={list.newTeam} onRun={() => void store.runAccounts({ action: "team.new" })} />
      </div>
      {list.notice && (
        <output className="row-help block" data-team-notice={list.notice.kind}>
          {list.notice.text}
        </output>
      )}
      <div className="rows">
        {list.create && (
          <div className="row accounts-row" data-team-create="">
            <div className="accounts-body accounts-team-body accounts-team-create">
              <TeamNameForm form={list.create} />
            </div>
          </div>
        )}
        {list.rows.map((row) => (
          <TeamRow key={row.id} row={row} />
        ))}
        {list.empty && (
          <div className="row" data-team-empty="">
            <div className="row-help">{list.empty}</div>
          </div>
        )}
      </div>
    </section>
  );
}

function TeamButton({ button, onRun }: { button: AccountsButton; onRun: () => void }) {
  return (
    <button
      type="button"
      className={button.destructive ? "button danger" : "button"}
      disabled={button.disabled}
      title={button.help ?? undefined}
      data-team-button={button.id}
      onClick={onRun}
    >
      {button.title}
    </button>
  );
}

function TeamRow({ row }: { row: AccountsTeamRow }) {
  const store = useStore();
  return (
    <div className="row accounts-row" data-team={row.id} data-team-open={row.open || undefined}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title accounts-team-title">
            {row.name}
            {row.active && <span className="accounts-badge">{row.active}</span>}
          </div>
          <div className="row-help" data-team-role={row.roleKind}>
            {row.role}
          </div>
        </div>
        <div className="row-control">
          <button
            type="button"
            className="button"
            aria-expanded={row.open}
            data-team-button={row.toggle.id}
            disabled={row.toggle.disabled}
            onClick={() => void store.runAccounts({ action: "team.details", team: row.id })}
          >
            {row.toggle.title}
          </button>
        </div>
      </div>
      {row.detail && <TeamDetails team={row.id} detail={row.detail} />}
    </div>
  );
}

function TeamDetails({ team, detail }: { team: string; detail: AccountsTeamDetails }) {
  const store = useStore();
  const run = (action: string) => void store.runAccounts({ action, team });
  return (
    <div className="accounts-body accounts-team-body" data-team-detail={team}>
      {detail.loading && <div className="row-help">{detail.loading}</div>}
      {detail.error && <div className="row-error">{detail.error}</div>}
      {detail.facts.length > 0 && (
        <dl className="accounts-facts">
          {detail.facts.map((fact) => (
            <div key={fact.label} className="accounts-fact">
              <dt className="row-help">{fact.label}</dt>
              <dd>{fact.value}</dd>
            </div>
          ))}
        </dl>
      )}
      {detail.members.length > 0 && (
        <div className="accounts-team-list" data-team-members="">
          <div className="row-title">{detail.membersTitle}</div>
          {detail.members.map((member) => (
            <div className="accounts-linked" key={member.id} data-team-member={member.id}>
              <span>{member.name}</span>
              {member.you && <span className="accounts-badge">{member.you}</span>}
              {member.detail && <span className="row-help">{member.detail}</span>}
              <span className="row-help accounts-team-role">{member.role}</span>
            </div>
          ))}
        </div>
      )}
      {detail.invitationsTitle && (
        <div className="accounts-team-list" data-team-invitations="">
          <div className="row-title">{detail.invitationsTitle}</div>
          {detail.noInvitations && <div className="row-help">{detail.noInvitations}</div>}
          {detail.invitations?.map((invitation) => (
            <div className="accounts-linked" key={invitation.id} data-team-invitation={invitation.id}>
              <span>{invitation.email}</span>
              <span className="row-help">{invitation.role}</span>
              {invitation.expires && <span className="row-help">{invitation.expires}</span>}
            </div>
          ))}
        </div>
      )}
      {detail.buttons.length > 0 && (
        <div className="accounts-buttons">
          {detail.buttons.map((button) => (
            <TeamButton key={button.id} button={button} onRun={() => run(button.id)} />
          ))}
        </div>
      )}
      {detail.readOnly && (
        <div className="row-help" data-team-read-only="">
          {detail.readOnly}
        </div>
      )}
      {detail.rename && <TeamNameForm form={detail.rename} team={team} />}
      {detail.confirm && (
        <div className="accounts-form" data-team-confirm={team} role="alertdialog" aria-label={detail.confirm.confirm}>
          <span>{detail.confirm.text}</span>
          {detail.confirm.error && (
            <div className="row-error" role="alert">
              {detail.confirm.error}
            </div>
          )}
          <div className="accounts-buttons">
            <button
              type="button"
              className="button danger"
              disabled={detail.confirm.busy}
              data-team-button="team.confirmDelete"
              onClick={() => run("team.confirmDelete")}
            >
              {detail.confirm.confirm}
            </button>
            <button
              type="button"
              className="button"
              disabled={detail.confirm.busy}
              data-team-button="team.cancel"
              onClick={() => run("team.cancel")}
            >
              {detail.confirm.cancel}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// New Team (no team) and Rename Team (the team's id): the name starts at the host's value, Return
// submits, Escape cancels. Submit stays off while the name is blank or a save runs; the host
// checks the length again and its refusal shows under the field.
function TeamNameForm({ form, team }: { form: AccountsTeamForm; team?: string }) {
  const store = useStore();
  const [name, setName] = useState(form.value);
  const blank = name.trim() === "";
  const submit = () => {
    if (blank || form.busy) return;
    void store.runAccounts(
      form.kind === "create" ? { action: "team.create", name } : { action: "team.saveName", team, name },
    );
  };
  const cancel = () => void store.runAccounts({ action: "team.cancel" });
  const keyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter") {
      event.preventDefault();
      submit();
    } else if (event.key === "Escape") {
      event.preventDefault();
      cancel();
    }
  };
  return (
    <div className="accounts-form" data-team-form={form.kind}>
      <div className="row-label">
        <div className="row-title">{form.title}</div>
        <div className="row-help">{form.help}</div>
      </div>
      <input
        className="field"
        type="text"
        aria-label={form.title}
        autoComplete="off"
        spellCheck={false}
        maxLength={form.maxLength}
        placeholder={form.placeholder}
        value={name}
        onChange={(event) => setName(event.target.value)}
        onKeyDown={keyDown}
      />
      {form.error && (
        <div className="row-error" role="alert">
          {form.error}
        </div>
      )}
      <div className="accounts-buttons">
        <button
          type="button"
          className="button"
          disabled={blank || form.busy}
          data-team-button="team.submit"
          onClick={submit}
        >
          {form.submit}
        </button>
        <button type="button" className="button" disabled={form.busy} data-team-button="team.cancel" onClick={cancel}>
          {form.cancel}
        </button>
      </div>
    </div>
  );
}
