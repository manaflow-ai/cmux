// Words Page Info's bubble and its Site settings window share (PageInfoStrings, PageInfoModel
// .choiceTitle): a permission's name and the title of each of its choices, the default marked.
import type { Strings } from "../../pages/shared/i18n";
import { defaultSetting, type SitePermissionKind, type SitePermissionSetting } from "./model";

export function permissionName(strings: Strings, kind: SitePermissionKind): string {
  return strings.t(`pageInfo.permission.${kind}`);
}

export function choiceTitle(strings: Strings, setting: SitePermissionSetting, kind: SitePermissionKind): string {
  const t = strings.t;
  const isDefault = setting === defaultSetting(kind);
  switch (setting) {
    case "ask":
      return t(isDefault ? "pageInfo.choice.askDefault" : "pageInfo.choice.ask");
    case "allow":
      if (kind === "sound") return t(isDefault ? "pageInfo.state.automaticDefault" : "pageInfo.choice.allow");
      return t(isDefault ? "pageInfo.choice.allowDefault" : "pageInfo.choice.allow");
    case "block":
      if (kind === "sound") return t("pageInfo.choice.mute");
      return t(isDefault ? "pageInfo.choice.blockDefault" : "pageInfo.choice.block");
  }
}
