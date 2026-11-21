// l10n-allow-file: gallery fixtures (sample sites), not shipped UI.
// Page Info's On-device site data window over sample sites. The stage answers a delete the way the
// host does (the site leaves the list).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { SiteDataWindow, type SiteDataLook } from "./SiteDataWindow";
import { siteData } from "./windowFixtures";
import type { SiteDataState } from "./windows";

type Props = { state: SiteDataState; look?: SiteDataLook };

function SiteDataFixture({ state, look }: Props) {
  const [now, setNow] = useState(state);
  return (
    <div style={{ width: 440 }}>
      <SiteDataWindow
        state={now}
        look={look}
        onCommand={(command) => {
          if (command.type !== "deleteSiteData") return;
          setNow((current) => ({
            entries: current.entries?.filter((entry) => entry.domain !== command.domain) ?? null,
          }));
        }}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "browser-chrome.page-info.site-data",
  title: "Page Info: On-device site data",
  area: "Browser chrome",
  experimental: true,
  height: 420,
  widths: { narrow: 460, normal: 500, wide: 580 },
  covers: ["browser-chrome/page-info/SiteDataWindow.tsx"],
  keywords: ["site data", "cookies", "storage", "delete", "third party"],
  load: async () => SiteDataFixture,
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "parity", label: "Parity" },
        { value: "grouped", label: "Grouped" },
        { value: "compact", label: "Compact" },
      ],
      defaultValue: "parity",
    },
  ],
  variants: {
    parity: { props: { state: siteData }, note: "Recommended look: today's native list." },
    grouped: { props: { state: siteData, look: "grouped" }, note: "This site and third parties under headings." },
    compact: { props: { state: siteData, look: "compact" }, note: "One line per site, details trailing." },
    loading: { props: { state: { entries: null } } },
    empty: { props: { state: { entries: [] } } },
  },
});
