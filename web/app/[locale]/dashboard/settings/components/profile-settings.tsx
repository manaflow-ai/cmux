"use client";

import { UserAvatar, useUser } from "@hexclave/next";
import { useTranslations } from "next-intl";
import {
  EditableText,
  ImageCropEditor,
  SettingsSection,
  SettingsStack,
} from "../../components/settings-ui";

/** `/dashboard/settings`: display name and profile image. */
export function ProfileSettings() {
  const t = useTranslations("dashboard.settings.profile");
  const user = useUser({ or: "redirect" });

  return (
    <SettingsStack>
      <SettingsSection title={t("displayNameTitle")} description={t("displayNameDescription")}>
        <EditableText
          label={t("displayNameTitle")}
          value={user.displayName ?? ""}
          emptyText={t("displayNameEmpty")}
          maxLength={100}
          onSave={(displayName) => user.update({ displayName })}
        />
      </SettingsSection>
      <SettingsSection title={t("imageTitle")} description={t("imageDescription")}>
        <ImageCropEditor
          label={t("imageUpload")}
          imageUrl={user.profileImageUrl}
          preview={<UserAvatar size={60} user={user} />}
          onSave={(profileImageUrl) => user.update({ profileImageUrl })}
          onRemove={() => user.update({ profileImageUrl: null })}
        />
      </SettingsSection>
    </SettingsStack>
  );
}
