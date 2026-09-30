"use client";

import { useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate } from "@tanstack/react-router";
import { useFormatter, useTranslations } from "next-intl";
import { useState } from "react";
import { ActionMenu, type ActionMenuItem } from "@/dashboard-app/components/settings-ui/action-menu";
import { ConfirmDialog } from "@/dashboard-app/components/settings-ui/confirm-dialog";
import { EmptyState } from "@/dashboard-app/components/page-states";
import { Badge, InlineError } from "@/dashboard-app/components/settings-ui/feedback";
import { SettingsPanel, SettingsStack } from "@/dashboard-app/components/settings-ui/settings-section";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { InviteLinkCreator, InviteLinksTable, InviteMembersForm } from "./invite-panel";
import {
  type TeamDetail,
  type TeamInvitation,
  type TeamMember,
  forgetTeam,
  useChangeRole,
  useLeaveTeam,
  useRemoveMember,
  useResendInvitation,
  useRevokeInvitation,
} from "@/dashboard-app/queries/teams";
import { type MemberActionId, memberActions } from "./member-actions";
import { RoleBadge, TeamAvatar, useTeamErrorText } from "./team-ui";
import { teamTabLink, useTeamContext } from "./team-shell";

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

/** Seats are soft: this never blocks an invite, it only points admins at billing. */

type PendingConfirm =
  | { readonly kind: "remove"; readonly member: TeamMember }
  | { readonly kind: "demoteSelf"; readonly member: TeamMember }
  | { readonly kind: "leave" };

/**
 * Member | Role | actions. Roles show as badges; every change goes through
 * the row's actions menu (see `memberActions`), so a row never offers a
 * control that can only fail.
 */
export function MembersTable({ detail }: { readonly detail: TeamDetail }) {
  const t = useTranslations("dashboard.teams.members");
  const general = useTranslations("dashboard.teams.general");
  const errorText = useTeamErrorText();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  // Mutations live here, not in the row: the optimistic update unmounts a
  // removed row, and a failure must still be reported after it comes back.
  const remove = useRemoveMember(detail.team.id);
  const changeRole = useChangeRole(detail.team.id);
  const leave = useLeaveTeam(detail.team.id);
  const [confirm, setConfirm] = useState<PendingConfirm | null>(null);
  const members = [...detail.members].sort(
    (a, b) => Number(b.isViewer) - Number(a.isViewer) || memberLabel(a).localeCompare(memberLabel(b)),
  );

  const select = (member: TeamMember, action: MemberActionId) => {
    switch (action) {
      case "makeAdmin":
        changeRole.mutate({ userId: member.userId, role: "admin" });
        return;
      case "makeMember":
        if (member.isViewer) setConfirm({ kind: "demoteSelf", member });
        else changeRole.mutate({ userId: member.userId, role: "member" });
        return;
      case "remove":
        setConfirm({ kind: "remove", member });
        return;
      case "leave":
        setConfirm({ kind: "leave" });
        return;
    }
  };

  const failure = changeRole.error ?? remove.error;
  return (
    <div className="grid gap-1">
      <div className="border border-border">
        <div className="hidden grid-cols-[1.6fr_1fr_2rem] gap-3 border-b border-border px-3 py-2 text-xs text-muted md:grid">
          <div>{t("memberColumn")}</div>
          <div>{t("roleColumn")}</div>
          <div className="sr-only">{t("actionsColumn")}</div>
        </div>
        <ul className="divide-y divide-border">
          {members.map((member) => (
            <MemberRow
              key={member.userId}
              member={member}
              actions={memberActions(detail, member).map((action) => ({
                id: action.id,
                label: t(`actions.${action.id}`),
                danger: action.id === "remove" || action.id === "leave",
                disabled: action.disabledReason !== undefined,
                disabledReason: action.disabledReason ? t("lastAdminReason") : undefined,
                onSelect: () => select(member, action.id),
              }))}
            />
          ))}
        </ul>
      </div>
      {failure ? <InlineError message={errorText(failure)} /> : null}
      <ConfirmDialog
        open={confirm?.kind === "remove"}
        onOpenChange={(open) => {
          if (!open) setConfirm(null);
        }}
        title={t("removeTitle", { name: confirm?.kind === "remove" ? memberLabel(confirm.member) : "" })}
        description={t("removeBody")}
        confirmLabel={t("remove")}
        onConfirm={async () => {
          // Optimistic: close now; the row returns with an inline error on failure.
          if (confirm?.kind === "remove") remove.mutate(confirm.member.userId);
        }}
      />
      <ConfirmDialog
        open={confirm?.kind === "demoteSelf"}
        onOpenChange={(open) => {
          if (!open) setConfirm(null);
        }}
        title={t("demoteSelfTitle")}
        description={t("demoteSelfBody")}
        confirmLabel={t("demoteSelfConfirm")}
        onConfirm={async () => {
          if (confirm?.kind === "demoteSelf") changeRole.mutate({ userId: confirm.member.userId, role: "member" });
        }}
      />
      <ConfirmDialog
        open={confirm?.kind === "leave"}
        onOpenChange={(open) => {
          if (!open) setConfirm(null);
        }}
        title={general("leaveConfirmTitle", { team: detail.team.displayName })}
        description={general("leaveConfirmBody")}
        confirmLabel={general("leaveAction")}
        describeError={errorText}
        onConfirm={async () => {
          await leave.mutateAsync(detail.viewer.userId);
          // Leave the team route before dropping its detail (see useDeleteTeam).
          await navigate({ to: "/dashboard/teams" });
          await forgetTeam(queryClient, detail.team.id);
        }}
      />
    </div>
  );
}

function memberLabel(member: TeamMember): string {
  return member.displayName || member.email || member.userId;
}

function MemberRow({
  member,
  actions,
}: {
  readonly member: TeamMember;
  readonly actions: readonly ActionMenuItem[];
}) {
  const t = useTranslations("dashboard.teams.members");
  const label = memberLabel(member);
  return (
    <li className="grid grid-cols-[1fr_auto] items-center gap-2 px-3 py-2 text-sm md:grid-cols-[1.6fr_1fr_2rem] md:gap-3">
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
      <div className="col-start-1 row-start-2 md:col-start-auto md:row-start-auto">
        <RoleBadge role={member.role} />
      </div>
      <div className="col-start-2 row-span-2 row-start-1 justify-self-end md:col-start-auto md:row-span-1 md:row-start-auto">
        <ActionMenu label={t("actionsFor", { name: label })} items={actions} />
      </div>
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

  if (invitations.length === 0) return <EmptyState title={t("pendingEmpty")} />;
  return (
    <div className="grid gap-1">
      <ul className="divide-y divide-border border border-border">
        {invitations.map((invitation) => {
          const email = invitation.email ?? t("unknownEmail");
          const resent = resend.isSuccess && resend.variables === invitation.id;
          return (
            <li key={invitation.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 text-sm">
              <span className="min-w-0 flex-1 truncate">{email}</span>
              <RoleBadge role={invitation.role} />
              <span className="text-xs text-muted">
                {resent
                  ? t("resent")
                  : t("expires", { at: format.dateTime(new Date(invitation.expiresAt), { dateStyle: "medium" }) })}
              </span>
              <ActionMenu
                label={t("actionsFor", { name: email })}
                items={[
                  {
                    id: "resend",
                    label: t("resend"),
                    disabled: resend.isPending && resend.variables === invitation.id,
                    onSelect: () => resend.mutate(invitation.id),
                  },
                  { id: "revoke", label: t("revoke"), danger: true, onSelect: () => revoke.mutate(invitation.id) },
                ]}
              />
            </li>
          );
        })}
      </ul>
      {resend.isError ? <InlineError message={errorText(resend.error)} /> : null}
      {revoke.isError ? <InlineError message={errorText(revoke.error)} /> : null}
    </div>
  );
}
