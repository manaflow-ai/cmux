"use client";

import { Link } from "@tanstack/react-router";
import { useFormatter, useTranslations } from "next-intl";
import { useState } from "react";
import { ConfirmDialog } from "@/dashboard-app/components/settings-ui/confirm-dialog";
import { Badge, InlineError } from "@/dashboard-app/components/settings-ui/feedback";
import { SettingsPanel, SettingsStack } from "@/dashboard-app/components/settings-ui/settings-section";
import { settingsButtonClass, settingsInputClass } from "@/dashboard-app/components/settings-ui/styles";
import { InviteLinkCreator, InviteLinksTable, InviteMembersForm } from "./invite-panel";
import {
  type TeamDetail,
  type TeamInvitation,
  type TeamMember,
  useChangeRole,
  useRemoveMember,
  useResendInvitation,
  useRevokeInvitation,
} from "@/dashboard-app/queries/teams";
import { RoleBadge, TeamAvatar, useTeamErrorText } from "./team-ui";
import { useTeamContext } from "./team-shell";

export function TeamMembers() {
  const detail = useTeamContext();
  const t = useTranslations("dashboard.teams.members");
  const canInvite = detail.viewer.permissions.inviteMembers;
  return (
    <SettingsStack>
      <SettingsPanel title={t("title")} description={t("count", { count: detail.members.length })}>
        <MembersTable detail={detail} />
      </SettingsPanel>
      {canInvite ? (
        <>
          <SettingsPanel title={t("inviteTitle")} description={t("inviteDescription")}>
            <div className="border border-border p-3">
              <InviteMembersForm teamId={detail.team.id} />
            </div>
          </SettingsPanel>
          <SettingsPanel title={t("pendingTitle")} description={t("pendingDescription")}>
            <PendingInvitations teamId={detail.team.id} invitations={detail.invitations} />
          </SettingsPanel>
          <SettingsPanel title={t("linksTitle")} description={t("linksDescription")}>
            <div className="grid gap-3 border border-border p-3">
              <InviteLinkCreator teamId={detail.team.id} />
              <InviteLinksTable teamId={detail.team.id} links={detail.links} />
            </div>
          </SettingsPanel>
        </>
      ) : null}
    </SettingsStack>
  );
}

function MembersTable({ detail }: { readonly detail: TeamDetail }) {
  const t = useTranslations("dashboard.teams.members");
  const errorText = useTeamErrorText();
  // Removal lives here, not in the row: the optimistic update unmounts the
  // row, and a failure must still be reported after it comes back.
  const remove = useRemoveMember(detail.team.id);
  const [removing, setRemoving] = useState<TeamMember | null>(null);
  const isAdmin = detail.viewer.role === "admin";
  const canRemove = isAdmin && detail.viewer.permissions.removeMembers;
  const members = [...detail.members].sort(
    (a, b) => Number(b.isViewer) - Number(a.isViewer) || memberLabel(a).localeCompare(memberLabel(b)),
  );
  return (
    <div className="grid gap-1">
      <div className="border border-border">
        <div className="hidden grid-cols-[1.6fr_1fr_auto] gap-3 border-b border-border px-3 py-2 text-xs text-muted md:grid">
          <div>{t("memberColumn")}</div>
          <div>{t("roleColumn")}</div>
          <div className="text-right">{isAdmin ? t("actionsColumn") : ""}</div>
        </div>
        <ul className="divide-y divide-border">
          {members.map((member) => (
            <MemberRow
              key={member.userId}
              teamId={detail.team.id}
              member={member}
              viewerIsAdmin={isAdmin}
              onRemove={canRemove && !member.isViewer ? () => setRemoving(member) : undefined}
            />
          ))}
        </ul>
      </div>
      {remove.isError ? <InlineError message={errorText(remove.error)} /> : null}
      <ConfirmDialog
        open={removing !== null}
        onOpenChange={(open) => {
          if (!open) setRemoving(null);
        }}
        title={t("removeTitle", { name: removing ? memberLabel(removing) : "" })}
        description={t("removeBody")}
        confirmLabel={t("remove")}
        onConfirm={async () => {
          // Optimistic: close now; the row returns with an inline error on failure.
          if (removing) remove.mutate(removing.userId);
        }}
      />
    </div>
  );
}

function memberLabel(member: TeamMember): string {
  return member.displayName || member.email || member.userId;
}

function MemberRow({
  teamId,
  member,
  viewerIsAdmin,
  onRemove,
}: {
  readonly teamId: string;
  readonly member: TeamMember;
  readonly viewerIsAdmin: boolean;
  readonly onRemove?: () => void;
}) {
  const t = useTranslations("dashboard.teams.members");
  const errorText = useTeamErrorText();
  const changeRole = useChangeRole(teamId);
  const label = memberLabel(member);

  return (
    <li className="grid gap-2 px-3 py-2 text-sm md:grid-cols-[1.6fr_1fr_auto] md:items-center md:gap-3">
      <div className="flex min-w-0 items-center gap-2.5">
        <TeamAvatar name={label} imageUrl={member.profileImageUrl} size={28} />
        <div className="min-w-0">
          <div className="flex min-w-0 items-center gap-1.5">
            <span className="truncate font-medium">{member.displayName || member.email || t("unnamed")}</span>
            {member.isViewer ? <Badge tone="outline">{t("you")}</Badge> : null}
          </div>
          {member.email && member.displayName ? <div className="truncate text-xs text-muted">{member.email}</div> : null}
        </div>
      </div>
      <div>
        {viewerIsAdmin ? (
          <select
            aria-label={t("roleFor", { name: label })}
            value={member.role}
            disabled={changeRole.isPending}
            onChange={(event) =>
              // Optimistic: the select updates now and reverts if the server
              // refuses, for example when this is the last admin.
              changeRole.mutate({ userId: member.userId, role: event.target.value === "admin" ? "admin" : "member" })
            }
            className={`${settingsInputClass} w-auto`}
          >
            <option value="member">{t("roleMember")}</option>
            <option value="admin">{t("roleAdmin")}</option>
          </select>
        ) : (
          <RoleBadge role={member.role} />
        )}
      </div>
      <div className="md:text-right">
        {onRemove ? (
          <button type="button" className={settingsButtonClass("secondary", "sm")} onClick={onRemove}>
            {t("remove")}
          </button>
        ) : null}
      </div>
      {changeRole.isError ? <InlineError message={errorText(changeRole.error)} className="md:col-span-3" /> : null}
    </li>
  );
}

export function PendingInvitations({
  teamId,
  invitations,
}: {
  readonly teamId: string;
  readonly invitations: readonly TeamInvitation[];
}) {
  const t = useTranslations("dashboard.teams.members");
  const format = useFormatter();
  const errorText = useTeamErrorText();
  const resend = useResendInvitation(teamId);
  const revoke = useRevokeInvitation(teamId);

  if (invitations.length === 0) return <p className="border border-border p-3 text-xs text-muted">{t("pendingEmpty")}</p>;
  return (
    <div className="grid gap-1">
      <ul className="divide-y divide-border border border-border">
        {invitations.map((invitation) => (
          <li key={invitation.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 text-sm">
            <span className="min-w-0 flex-1 truncate">{invitation.email ?? t("unknownEmail")}</span>
            <RoleBadge role={invitation.role} />
            <span className="text-xs text-muted">
              {t("expires", { at: format.dateTime(new Date(invitation.expiresAt), { dateStyle: "medium" }) })}
            </span>
            <button
              type="button"
              className={settingsButtonClass("secondary", "sm")}
              disabled={resend.isPending && resend.variables === invitation.id}
              onClick={() => resend.mutate(invitation.id)}
            >
              {resend.isSuccess && resend.variables === invitation.id ? t("resent") : t("resend")}
            </button>
            <button
              type="button"
              className={settingsButtonClass("ghost", "sm")}
              onClick={() => revoke.mutate(invitation.id)}
            >
              {t("revoke")}
            </button>
          </li>
        ))}
      </ul>
      {resend.isError ? <InlineError message={errorText(resend.error)} /> : null}
      {revoke.isError ? <InlineError message={errorText(revoke.error)} /> : null}
    </div>
  );
}
