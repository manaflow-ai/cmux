// l10n-allow-file: gallery fixtures (sample sites), not shipped UI.
// Page Info's Site settings window over a sample site. The stage answers the window's commands the
// way the host does (a choice is stored, Reset clears them), so every menu can be used.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { SiteSettingsWindow, type SiteSettingsLook } from "./SiteSettingsWindow";
import { siteSettings } from "./windowFixtures";
import type { PageInfoWindowCommand, SiteSettingsState } from "./windows";
import { defaultSetting } from "./model";

type Props = { state: SiteSettingsState; look?: SiteSettingsLook };

function apply(state: SiteSettingsState, command: PageInfoWindowCommand): SiteSettingsState {
  const permissions =
    command.type === "setPermission"
      ? state.permissions.map((row) =>
          row.kind === command.kind ? { ...row, setting: command.setting, isDefault: false } : row,
        )
      : command.type === "resetPermissions"
        ? state.permissions.map((row) => ({ ...row, setting: defaultSetting(row.kind), isDefault: true }))
        : state.permissions;
  const canReset = permissions.some((row) => row.setting !== defaultSetting(row.kind));
  return { ...state, permissions, canReset };
}

function SiteSettingsFixture({ state, look }: Props) {
  const [now, setNow] = useState(state);
  return (
    <div style={{ width: 460 }}>
      <SiteSettingsWindow
        state={now}
        look={look}
        onCommand={(command) => setNow((current) => apply(current, command))}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "browser-chrome.page-info.site-settings",
  title: "Page Info: Site settings",
  area: "Browser chrome",
  experimental: true,
  height: 620,
  widths: { narrow: 480, normal: 520, wide: 600 },
  covers: ["browser-chrome/page-info/SiteSettingsWindow.tsx"],
  keywords: ["site settings", "permissions", "usage", "delete data", "reset permissions"],
  load: async () => SiteSettingsFixture,
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "parity", label: "Parity" },
        { value: "grouped", label: "Grouped" },
        { value: "segmented", label: "Segmented" },
      ],
      defaultValue: "parity",
    },
  ],
  variants: {
    parity: { props: { state: siteSettings }, note: "Recommended look: today's native window." },
    grouped: { props: { state: siteSettings, look: "grouped" }, note: "Each section on its own inset card." },
    segmented: {
      props: { state: siteSettings, look: "segmented" },
      note: "Every choice on the row; no menu to open, but long rows on narrow windows.",
    },
    loading: { props: { state: { ...siteSettings, usage: null, canReset: false } }, note: "Usage still loading." },
  },
});
