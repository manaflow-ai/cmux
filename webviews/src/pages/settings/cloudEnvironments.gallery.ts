// l10n-allow-file: gallery fixtures, not shipped UI.
import { settingsPageEntry } from "../../gallery/format";

export default settingsPageEntry({
  id: "pages.settings-cloud",
  title: "Settings Cloud",
  area: "Settings",
  height: 820,
  widths: { narrow: 446 },
  covers: ["pages/settings/components/CloudEnvironmentsCard.tsx#CloudEnvironmentsCard"],
  variants: {
    empty: { section: "cloud" },
    "environments-unsupported": {
      section: "cloud",
      environments: { available: false, unsupported: true, loading: false, environments: [], error: null },
    },
  },
});
