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
    "default-image-late-list": {
      section: "cloud",
      environments: { available: false, loading: true, environments: [], error: null },
      environmentsLate: {
        reads: 2,
        then: {
          available: true,
          loading: false,
          error: null,
          environments: [
            {
              id: "env_00000000000000000001",
              name: "start-matrix",
              repo: "manaflow-ai/cmux@feat-cmux-next",
              setup_script: "bun install",
              env: [],
              status: "ready",
              error: null,
              log_tail: null,
            },
          ],
        },
      },
      note: "Settings opened right after sign-in: the first environment reads find the list not read yet (hq probe run 46109146613); the Default Image menu reads again and lists the account's environment.",
    },
  },
});
