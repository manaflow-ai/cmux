"use client";

import { type CurrentUser, type Team as StackTeam, useUser } from "@hexclave/next";
import { useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import { Suspense, useState } from "react";
import { ConfirmDialog } from "@/dashboard-app/components/settings-ui/confirm-dialog";
import { EditableText } from "@/dashboard-app/components/settings-ui/editable-text";
import { ImageCropEditor } from "@/dashboard-app/components/settings-ui/image-crop-editor";
import { SettingsSection, SettingsStack } from "@/dashboard-app/components/settings-ui/settings-section";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import {
  forgetTeam,
  isLastAdmin,
  type TeamDetail,
  teamErrorCode,
  teamQueryKeys,
  useDeleteTeam,
  useRemoveMember,
  useUpdateTeam,
} from "@/dashboard-app/queries/teams";
import { TEAM_NAME_MAX_LENGTH, validateTeamName } from "./team-logic";
import { TeamAvatar, useTeamErrorText } from "./team-ui";
import { teamTabLink, useTeamContext } from "./team-shell";

export function TeamGeneral() {
  const detail = useTeamContext();
  return (
    <SettingsStack>
      {detail.viewer.permissions.updateTeam ? <TeamImageSection detail={detail} /> : null}
      <TeamNameSection detail={detail} />
      <Suspense fallback={null}>
        <MyTeamProfileSection teamId={detail.team.id} />
      </Suspense>
      <LeaveTeamSection detail={detail} />
      {detail.viewer.permissions.deleteTeam ? <DeleteTeamSection detail={detail} /> : null}
    </SettingsStack>
  );
}

function TeamImageSection({ detail }: { readonly detail: TeamDetail }) {
  const t = useTranslations("dashboard.teams.general");
  const update = useUpdateTeam(detail.team.id);
  return (
    <SettingsSection title={t("imageTitle")} description={t("imageDescription")}>
      <ImageCropEditor
        label={t("imageUpload")}
        imageUrl={detail.team.profileImageUrl}
        preview={<TeamAvatar name={detail.team.displayName} imageUrl={detail.team.profileImageUrl} size={48} />}
        onSave={async (dataUrl) => {
          await update.mutateAsync({ profileImageUrl: dataUrl });
        }}
        onRemove={async () => {
          await update.mutateAsync({ profileImageUrl: null });
        }}
      />
    </SettingsSection>
  );
}

function TeamNameSection({ detail }: { readonly detail: TeamDetail }) {
  const t = useTranslations("dashboard.teams.general");
  const update = useUpdateTeam(detail.team.id);
  const canEdit = detail.viewer.permissions.updateTeam;
  const errorText = useTeamErrorText();

  return (
    <SettingsSection title={t("nameTitle")} description={canEdit ? t("nameDescription") : t("nameReadOnly")}>
      {canEdit ? (
        <EditableText
          label={t("nameTitle")}
          value={detail.team.displayName}
          maxLength={TEAM_NAME_MAX_LENGTH}
          describeError={errorText}
          onSave={async (value) => {
            // EditableText already trims and rejects empty input; this also
            // enforces the length cap before the request.
            const result = validateTeamName(value);
            if (!result.ok) throw new Error(result.reason);
            // Optimistic: the header shows the new name now and reverts on failure.
            await update.mutateAsync({ displayName: result.value });
          }}
        />
      ) : (
        <p className="text-sm">{detail.team.displayName}</p>
      )}
    </SettingsSection>
  );
}

/**
 * The viewer's own name inside this team. Stack stores it per membership,
 * so it is edited through the Stack client SDK instead of the Team API.
 */
function MyTeamProfileSection({ teamId }: { readonly teamId: string }) {
  const t = useTranslations("dashboard.teams.general");
  const user = useUser({ or: "redirect" });
  const team = user.useTeam(teamId);
  if (!team) return null;
  return (
    <SettingsSection title={t("profileTitle")} description={t("profileDescription")}>
      <MyTeamProfileName user={user} team={team} />
    </SettingsSection>
  );
}

function MyTeamProfileName({ user, team }: { readonly user: CurrentUser; readonly team: StackTeam }) {
  const t = useTranslations("dashboard.teams.general");
  const profile = user.useTeamProfile(team);
  const queryClient = useQueryClient();
  return (
    <EditableText
      label={t("profileLabel")}
      value={profile.displayName ?? ""}
      emptyText={user.displayName ?? undefined}
      maxLength={TEAM_NAME_MAX_LENGTH}
      onSave={async (displayName) => {
        await profile.update({ displayName });
        await queryClient.invalidateQueries({ queryKey: teamQueryKeys.detail(team.id) });
      }}
    />
  );
}

function LeaveTeamSection({ detail }: { readonly detail: TeamDetail }) {
  const t = useTranslations("dashboard.teams.general");
  const errorText = useTeamErrorText();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const leave = useRemoveMember(detail.team.id);
  const [open, setOpen] = useState(false);
  const lastAdmin = isLastAdmin(detail);

  return (
    <SettingsSection title={t("leaveTitle")} description={t("leaveDescription")}>
      {lastAdmin ? (
        <p className="text-xs text-muted" data-testid="leave-blocked">
          {t("leaveBlocked")}
        </p>
      ) : (
        <button type="button" className={settingsButtonClass("secondary")} onClick={() => setOpen(true)}>
          {t("leaveAction")}
        </button>
      )}
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={t("leaveConfirmTitle", { team: detail.team.displayName })}
        description={t("leaveConfirmBody")}
        confirmLabel={t("leaveAction")}
        describeError={errorText}
        onConfirm={async () => {
          await leave.mutateAsync(detail.viewer.userId);
          // Leave the team route before dropping its detail (see useDeleteTeam).
          await navigate({ to: "/dashboard/teams" });
          await forgetTeam(queryClient, detail.team.id);
        }}
      />
    </SettingsSection>
  );
}

function DeleteTeamSection({ detail }: { readonly detail: TeamDetail }) {
  const t = useTranslations("dashboard.teams.general");
  const errorText = useTeamErrorText();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const remove = useDeleteTeam(detail.team.id);
  const [open, setOpen] = useState(false);
  const [activeSubscription, setActiveSubscription] = useState(false);

  return (
    <SettingsSection title={t("deleteTitle")} description={t("deleteDescription")} tone="danger">
      <button
        type="button"
        className={settingsButtonClass("danger")}
        onClick={() => {
          setActiveSubscription(false);
          setOpen(true);
        }}
      >
        {t("deleteAction")}
      </button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={t("deleteConfirmTitle", { team: detail.team.displayName })}
        description={t("deleteConfirmBody")}
        confirmLabel={t("deleteAction")}
        typedConfirmation={detail.team.displayName}
        describeError={errorText}
        onConfirm={async () => {
          try {
            await remove.mutateAsync();
          } catch (error) {
            setActiveSubscription(teamErrorCode(error) === "team_has_active_subscription");
            throw error;
          }
          await navigate({ to: "/dashboard/teams" });
          await forgetTeam(queryClient, detail.team.id);
        }}
      >
        {activeSubscription ? (
          <Link {...teamTabLink(detail.team.id, "billing")} className={settingsButtonClass("secondary", "sm")}>
            {t("openBilling")}
          </Link>
        ) : null}
      </ConfirmDialog>
    </SettingsSection>
  );
}
