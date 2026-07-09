"use client";

import { useMemo, useState, useTransition } from "react";
import { useTranslations } from "next-intl";

import type { TeamInvitationDto, TeamMemberDto, TeamSummaryDto } from "@/services/team/invites";
import { applyOptimisticRevoke } from "./optimistic";

type TeamRole = "admin" | "member";

type InviteStatus = {
  readonly email: string;
  readonly state: "pending" | "sent" | "failed";
  readonly message: string | null;
};

export function TeamManagerClient({
  initialSummary,
  currentUserId,
  locale,
  joined,
}: {
  initialSummary: TeamSummaryDto;
  currentUserId: string;
  locale: string;
  joined: boolean;
}) {
  const t = useTranslations("dashboard.team");
  const [summary, setSummary] = useState(initialSummary);
  const [chips, setChips] = useState<string[]>([]);
  const [input, setInput] = useState("");
  const [statuses, setStatuses] = useState<InviteStatus[]>([]);
  const [inviteRole, setInviteRole] = useState<TeamRole>("member");
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [isPending, startTransition] = useTransition();
  const overSeats = summary.seats > 0 && summary.members.length > summary.seats;
  const canManageTeam = summary.canManageTeam;
  const adminCount = summary.members.filter((member) => member.role === "admin").length;

  const shareUrl = useMemo(() => {
    const first = summary.invitations.find((invite) => invite.acceptUrl)?.acceptUrl;
    return first ?? null;
  }, [summary.invitations]);

  function addInputEmails(raw: string) {
    const parts = raw.split(/[,\s]+/).map((part) => part.trim()).filter(Boolean);
    if (parts.length === 0) return;
    setChips((current) => Array.from(new Set([...current, ...parts.map((part) => part.toLowerCase())])));
    setInput("");
  }

  async function sendInvites() {
    const emails = [...chips];
    if (input.trim()) {
      emails.push(...input.split(/[,\s]+/).map((part) => part.trim()).filter(Boolean));
    }
    const unique = Array.from(new Set(emails.map((email) => email.toLowerCase())));
    setChips(unique);
    setStatuses(unique.map((email) => ({ email, state: "pending", message: null })));
    for (const email of unique) {
      try {
        const response = await fetch("/api/team/invite", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ email, locale, role: inviteRole }),
        });
        const body = await response.json() as { invitation?: TeamInvitationDto; error?: string };
        if (!response.ok || !body.invitation) throw new Error(body.error ?? "failed");
        setSummary((current) => ({
          ...current,
          invitations: [
            body.invitation!,
            ...current.invitations.filter((invite) => invite.id !== body.invitation!.id),
          ],
        }));
        setStatuses((current) => updateStatus(current, email, "sent", t("invite.sent")));
      } catch {
        setStatuses((current) => updateStatus(current, email, "failed", t("errors.inviteFailed")));
      }
    }
    setChips([]);
    setInput("");
  }

  function revoke(invitationId: string) {
    const mutation = applyOptimisticRevoke(summary, invitationId, crypto.randomUUID());
    setSummary(mutation.next);
    startTransition(async () => {
      try {
        const response = await fetch("/api/team/invite/revoke", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ invitationId }),
        });
        const body = await response.json() as TeamSummaryDto | { error?: string };
        if (!response.ok || !("teamId" in body)) throw new Error("failed");
        setSummary(body);
      } catch {
        setSummary(mutation.previous);
        setError(t("errors.revokeFailed"));
      }
    });
  }

  function resend(invitationId: string) {
    startTransition(async () => {
      try {
        const response = await fetch("/api/team/invite/resend", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ invitationId, locale }),
        });
        if (!response.ok) throw new Error("failed");
        setError(null);
      } catch {
        setError(t("errors.resendFailed"));
      }
    });
  }

  function removeMember(memberId: string) {
    if (!confirm(memberId === currentUserId ? t("members.leaveConfirm") : t("members.removeConfirm"))) return;
    startTransition(async () => {
      try {
        const response = await fetch("/api/team/members/remove", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ memberId }),
        });
        const body = await response.json() as TeamSummaryDto | { error?: string };
        if (!response.ok || !("teamId" in body)) throw new Error("failed");
        setSummary(body);
        setError(null);
      } catch {
        setError(t("errors.removeFailed"));
      }
    });
  }

  function updateRole(memberId: string, role: TeamRole) {
    startTransition(async () => {
      try {
        const response = await fetch("/api/team/members/role", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ memberId, role }),
        });
        const body = await response.json() as TeamSummaryDto | { error?: string };
        if (!response.ok || !("teamId" in body)) throw new Error("failed");
        setSummary(body);
        setError(null);
      } catch {
        setError(t("errors.roleFailed"));
      }
    });
  }

  async function copyInviteLink() {
    const url = shareUrl;
    if (!url) {
      setError(t("invite.copyUnavailable"));
      return;
    }
    await navigator.clipboard.writeText(url);
    setCopied(true);
  }

  return (
    <div className="space-y-4">
      {joined ? (
        <div className="border border-border p-3 text-sm">{t("joinedBanner")}</div>
      ) : null}
      {error ? <div className="border border-border p-3 text-sm">{error}</div> : null}
      <section className="border border-border p-3">
        <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
          <div>
            <h2 className="text-sm font-medium">{summary.teamName}</h2>
            <p className="mt-1 text-xs text-muted">
              {t("seatSummary", { members: summary.members.length, seats: summary.seats })}
            </p>
            {overSeats ? (
              <a
                href="/api/billing/portal?scope=team"
                className="mt-2 inline-block text-xs text-muted underline hover:text-foreground"
              >
                {t("seatNudge")}
              </a>
            ) : null}
          </div>
          {canManageTeam ? <RenameForm currentName={summary.teamName} onRenamed={setSummary} /> : null}
        </div>
      </section>

      {canManageTeam ? (
        <section className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("invite.title")}</h2>
        <div className="mt-3 flex flex-wrap gap-2">
          {chips.map((email) => (
            <button
              key={email}
              type="button"
              onClick={() => setChips((current) => current.filter((item) => item !== email))}
              className="border border-border px-2 py-1 text-xs"
            >
              {email}
            </button>
          ))}
        </div>
        <div className="mt-3 flex flex-col gap-2 md:flex-row">
          <input
            value={input}
            onChange={(event) => setInput(event.target.value)}
            onBlur={() => addInputEmails(input)}
            onKeyDown={(event) => {
              if (event.key === "Enter" || event.key === ",") {
                event.preventDefault();
                addInputEmails(input);
              }
            }}
            placeholder={t("invite.placeholder")}
            className="min-w-0 flex-1 border border-border bg-background px-3 py-2 text-sm focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          />
          <select
            value={inviteRole}
            onChange={(event) => setInviteRole(event.target.value as TeamRole)}
            aria-label={t("invite.roleLabel")}
            className="border border-border bg-background px-3 py-2 text-sm"
          >
            <option value="member">{t("roles.member")}</option>
            <option value="admin">{t("roles.admin")}</option>
          </select>
          <button
            type="button"
            disabled={isPending}
            onClick={sendInvites}
            className="border border-border px-3 py-2 text-sm hover:bg-foreground hover:text-background disabled:opacity-50"
          >
            {t("invite.send")}
          </button>
          <button
            type="button"
            onClick={copyInviteLink}
            className="border border-border px-3 py-2 text-sm hover:bg-foreground hover:text-background"
          >
            {copied ? t("invite.copied") : t("invite.copyLink")}
          </button>
        </div>
        {statuses.length > 0 ? (
          <div className="mt-3 space-y-1 text-xs">
            {statuses.map((status) => (
              <p key={status.email}>
                {status.email}: {status.message ?? t(`invite.${status.state}`)}
              </p>
            ))}
          </div>
        ) : null}
        </section>
      ) : null}

      <section className="border border-border">
        <div className="border-b border-border px-3 py-2 text-sm font-medium">{t("pending.title")}</div>
        {summary.invitations.length === 0 ? (
          <p className="p-3 text-xs text-muted">{t("pending.empty")}</p>
        ) : summary.invitations.map((invitation) => (
          <InviteRow
            key={invitation.id}
            invitation={invitation}
            canManageTeam={canManageTeam}
            onResend={() => resend(invitation.id)}
            onRevoke={() => revoke(invitation.id)}
          />
        ))}
      </section>

      <section className="border border-border">
        <div className="border-b border-border px-3 py-2 text-sm font-medium">{t("members.title")}</div>
        {summary.members.map((member) => (
          <MemberRow
            key={member.id}
            member={member}
            currentUserId={currentUserId}
            memberCount={summary.members.length}
            adminCount={adminCount}
            canManageTeam={canManageTeam}
            onRemove={() => removeMember(member.id)}
            onRoleChange={(role) => updateRole(member.id, role)}
          />
        ))}
      </section>
    </div>
  );
}

function RenameForm({
  currentName,
  onRenamed,
}: {
  currentName: string;
  onRenamed: (summary: TeamSummaryDto) => void;
}) {
  const t = useTranslations("dashboard.team");
  const [name, setName] = useState(currentName);
  const [isPending, startTransition] = useTransition();
  return (
    <form
      className="flex gap-2"
      onSubmit={(event) => {
        event.preventDefault();
        startTransition(async () => {
          const response = await fetch("/api/team", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ action: "rename", displayName: name }),
          });
          const body = await response.json() as TeamSummaryDto;
          if (response.ok) onRenamed(body);
        });
      }}
    >
      <input
        value={name}
        onChange={(event) => setName(event.target.value)}
        aria-label={t("rename.label")}
        className="w-44 border border-border bg-background px-2 py-1 text-sm"
      />
      <button type="submit" disabled={isPending} className="border border-border px-2 py-1 text-sm disabled:opacity-50">
        {t("rename.save")}
      </button>
    </form>
  );
}

function InviteRow({
  invitation,
  canManageTeam,
  onResend,
  onRevoke,
}: {
  invitation: TeamInvitationDto;
  canManageTeam: boolean;
  onResend: () => void;
  onRevoke: () => void;
}) {
  const t = useTranslations("dashboard.team");
  return (
    <div className="grid gap-2 border-b border-border px-3 py-2 last:border-b-0 md:grid-cols-[1fr_auto] md:items-center">
      <div>
        <div className="text-sm">{invitation.email}</div>
        <div className="text-xs text-muted">
          {invitation.createdAt ?? t("pending.unknownDate")} · {t(`roles.${invitation.role}`)}
        </div>
      </div>
      {canManageTeam ? <div className="flex gap-2">
        <button type="button" onClick={onResend} className="border border-border px-2 py-1 text-xs">
          {t("pending.resend")}
        </button>
        <button type="button" onClick={onRevoke} className="border border-border px-2 py-1 text-xs">
          {t("pending.revoke")}
        </button>
      </div> : null}
    </div>
  );
}

function MemberRow({
  member,
  currentUserId,
  memberCount,
  adminCount,
  canManageTeam,
  onRemove,
  onRoleChange,
}: {
  member: TeamMemberDto;
  currentUserId: string;
  memberCount: number;
  adminCount: number;
  canManageTeam: boolean;
  onRemove: () => void;
  onRoleChange: (role: TeamRole) => void;
}) {
  const t = useTranslations("dashboard.team");
  const isSelf = member.id === currentUserId;
  const isLastAdmin = member.role === "admin" && adminCount <= 1;
  const canLeave = isSelf && memberCount > 1 && !isLastAdmin;
  const canRemove = canManageTeam && !isSelf && memberCount > 1 && !isLastAdmin;
  const label = member.displayName ?? member.email ?? member.id;
  return (
    <div className="grid gap-2 border-b border-border px-3 py-2 last:border-b-0 md:grid-cols-[auto_1fr_auto_auto] md:items-center">
      <div className="flex h-8 w-8 items-center justify-center border border-border text-xs">
        {label.slice(0, 1).toUpperCase()}
      </div>
      <div className="min-w-0">
        <div className="truncate text-sm">
          {label} {isSelf ? <span className="text-xs text-muted">{t("members.you")}</span> : null}
        </div>
        <div className="truncate text-xs text-muted">
          {member.email ?? t("members.noEmail")} · {t(`roles.${member.role}`)}
        </div>
      </div>
      {canManageTeam ? (
        <select
          value={member.role}
          disabled={isLastAdmin}
          onChange={(event) => onRoleChange(event.target.value as TeamRole)}
          aria-label={t("members.roleLabel")}
          className="border border-border bg-background px-2 py-1 text-xs disabled:opacity-50"
        >
          <option value="member">{t("roles.member")}</option>
          <option value="admin">{t("roles.admin")}</option>
        </select>
      ) : null}
      {canRemove || canLeave ? (
        <button
          type="button"
          onClick={onRemove}
          className="border border-border px-2 py-1 text-xs"
        >
          {isSelf ? t("members.leave") : t("members.remove")}
        </button>
      ) : null}
    </div>
  );
}

function updateStatus(
  statuses: readonly InviteStatus[],
  email: string,
  state: InviteStatus["state"],
  message: string,
): InviteStatus[] {
  return statuses.map((status) => status.email === email ? { ...status, state, message } : status);
}
