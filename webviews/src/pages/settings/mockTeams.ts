// l10n-allow-file: mock host fixtures (the app localizes these texts), not shipped UI.
// The Teams part of Settings > Accounts as the app's AccountsTeamsModel serves it, for the mock
// provider (tests) and the gallery: Personal (you are its admin, active) and Acme (you are a
// member). It answers like the cmux team API: rename and delete need admin, a team with a
// subscription cannot be deleted, and create makes you the admin of a new active team.
import type { AccountsButton, AccountsRun, AccountsTeamForm, AccountsTeamList, AccountsTeamRow } from "./ops";

type Role = "admin" | "member";
type MockTeam = { id: string; name: string; role: Role; subscribed: boolean };
type Form = { kind: "create" } | { kind: "rename" | "delete"; team: string };

const button = (id: string, title: string, disabled = false, destructive = false): AccountsButton => ({
  id,
  title,
  disabled,
  help: null,
  destructive,
});

const roleLabel = (role: Role | null) => (role === "admin" ? "Admin" : role === "member" ? "Member" : "Role unknown");

export class MockTeams {
  teams: MockTeam[] = [
    { id: "team-personal", name: "Personal", role: "admin", subscribed: false },
    { id: "team-acme", name: "Acme", role: "member", subscribed: false },
  ];
  active = "team-personal";
  /** The sign-in service alone answered: no roles. */
  rolesUnknown = false;
  open: string | null = null;
  form: Form | null = null;
  formError: string | null = null;
  notice: string | null = null;
  private created = 0;

  /** The state the host sends (`teamList`). */
  state(): AccountsTeamList {
    const create = this.form?.kind === "create" ? this.nameForm("create", "") : null;
    return {
      title: "Teams",
      newTeam: button("team.new", "New Team…"),
      rows: this.teams.map((team) => this.row(team)),
      empty:
        this.teams.length === 0 ? "You are not in a team yet. Create one to share Cloud machines and settings." : null,
      create,
      notice: this.notice ? { kind: "success", text: this.notice } : null,
    };
  }

  /** One `team.*` gesture; answers the failure text of a create, rename or delete. */
  run(run: AccountsRun): string | null {
    const gesture = run.action.slice("team.".length);
    if (gesture !== "cancel") this.notice = null;
    switch (gesture) {
      case "details":
        this.open = this.open === run.team ? null : (run.team ?? null);
        if (this.form?.kind !== "create") this.form = null;
        this.formError = null;
        return null;
      case "new":
        this.form = { kind: "create" };
        this.formError = null;
        return null;
      case "rename":
      case "delete":
        this.form = { kind: gesture, team: run.team ?? "" };
        this.formError = null;
        return null;
      case "cancel":
        this.form = null;
        this.formError = null;
        return null;
      case "create":
        return this.create(run.name ?? "");
      case "saveName":
        return this.rename(run.team ?? "", run.name ?? "");
      case "confirmDelete":
        return this.delete(run.team ?? "");
      default:
        return null;
    }
  }

  private fail(message: string): string {
    this.formError = message;
    return message;
  }

  private validName(name: string): string | null {
    const trimmed = name.trim();
    return trimmed.length >= 1 && trimmed.length <= 64 ? trimmed : null;
  }

  private create(name: string): string | null {
    const valid = this.validName(name);
    if (!valid) return this.fail("Enter a team name of 1 to 64 characters.");
    this.created += 1;
    const team = { id: `team-new-${this.created}`, name: valid, role: "admin" as const, subscribed: false };
    this.teams = [...this.teams, team];
    this.active = team.id;
    this.form = null;
    this.formError = null;
    this.notice = `Created “${valid}”. It is now your active team.`;
    return null;
  }

  private rename(id: string, name: string): string | null {
    const valid = this.validName(name);
    if (!valid) return this.fail("Enter a team name of 1 to 64 characters.");
    const team = this.teams.find((candidate) => candidate.id === id);
    if (!team) return this.fail("This team no longer exists.");
    if (team.role !== "admin") return this.fail("Only team admins can do this.");
    this.teams = this.teams.map((candidate) => (candidate.id === id ? { ...candidate, name: valid } : candidate));
    this.form = null;
    this.formError = null;
    this.notice = `Renamed the team to “${valid}”.`;
    return null;
  }

  private delete(id: string): string | null {
    const team = this.teams.find((candidate) => candidate.id === id);
    if (!team) return this.fail("This team no longer exists.");
    if (team.role !== "admin") return this.fail("Only team admins can do this.");
    if (team.subscribed) {
      return this.fail("This team has an active subscription. Cancel it in Billing, then delete the team.");
    }
    this.teams = this.teams.filter((candidate) => candidate.id !== id);
    this.form = null;
    this.formError = null;
    if (this.open === id) this.open = null;
    const wasActive = this.active === id;
    if (wasActive) this.active = this.teams[0]?.id ?? "";
    const now = this.teams.find((candidate) => candidate.id === this.active);
    this.notice =
      wasActive && now ? `Deleted “${team.name}”. “${now.name}” is now your active team.` : `Deleted “${team.name}”.`;
    return null;
  }

  private nameForm(kind: "create" | "rename", value: string): AccountsTeamForm {
    return {
      kind,
      title: kind === "create" ? "New Team" : "Rename Team",
      help:
        kind === "create" ? "You become the team's admin, and it becomes your active team." : "Up to 64 characters.",
      value,
      placeholder: "Team name",
      maxLength: 64,
      submit: kind === "create" ? "Create Team" : "Save",
      cancel: "Cancel",
      error: this.formError,
      busy: false,
    };
  }

  private row(team: MockTeam): AccountsTeamRow {
    const role = this.rolesUnknown ? null : team.role;
    const open = this.open === team.id;
    return {
      id: team.id,
      name: team.name,
      role: roleLabel(role),
      roleKind: role ?? "unknown",
      active: team.id === this.active ? "Active" : null,
      open,
      toggle: button("team.details", open ? "Hide Details" : "Details"),
      detail: open ? this.detail(team) : null,
    };
  }

  private detail(team: MockTeam): AccountsTeamRow["detail"] {
    const admin = team.role === "admin";
    const editing = this.form !== null && this.form.kind !== "create";
    const members = [
      { id: "user-you", name: "Sample User", detail: "sample@example.com", role: roleLabel(team.role), you: "You" },
      ...(team.id === "team-acme"
        ? [{ id: "user-ada", name: "Ada Lovelace", detail: "ada@example.com", role: "Admin", you: null }]
        : []),
    ];
    const form = this.form;
    return {
      loading: null,
      error: null,
      facts: [
        { label: "Your role", value: roleLabel(team.role) },
        { label: "Members", value: String(members.length) },
        { label: "Plan", value: team.subscribed ? "Team" : "Free" },
      ],
      membersTitle: "Members",
      members,
      invitationsTitle: admin ? "Pending Invitations" : null,
      invitations: admin
        ? [{ id: "invite-1", email: "grace@example.com", role: "Member", expires: "Expires Nov 2, 2026" }]
        : null,
      noInvitations: null,
      buttons: admin
        ? [button("team.rename", "Rename…", editing), button("team.delete", "Delete Team…", editing, true)]
        : [],
      readOnly: admin ? null : "Only team admins can rename or delete this team.",
      rename: form?.kind === "rename" && form.team === team.id ? this.nameForm("rename", team.name) : null,
      confirm:
        form?.kind === "delete" && form.team === team.id
          ? {
              text: `Delete “${team.name}”? Its members lose access to the team's Cloud machines and settings. This cannot be undone.`,
              confirm: "Delete Team",
              cancel: "Cancel",
              error: this.formError,
              busy: false,
            }
          : null,
    };
  }
}
