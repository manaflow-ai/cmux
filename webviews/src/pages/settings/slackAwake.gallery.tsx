// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { useEffect, useState } from "react";
import { SlackAwakeCard } from "./components/SlackAwakeCard";
import type { SlackAwake, SlackNames } from "./slackAwake";
import { installCatalog } from "./strings";
import table from "./generated/strings.json";

const TODAY = "2026-11-26";
const names: SlackNames = { U0OWNER: "Leo", U0AUSTIN: "Austin", U0LAWRENCE: "Lawrence", U0GUEST: "guest-contractor" };
const base: SlackAwake = { allowance_seconds: 7200, default_seconds: 7200, max_seconds: 86400, days: 7, senders: [] };
const busyDay: SlackAwake = {
  ...base,
  senders: [
    { slack_team: "T1", slack_user: "U0OWNER", sender_is_owner: true, day: TODAY, seconds: 5400, turns: 14 },
    { slack_team: "T1", slack_user: "U0AUSTIN", sender_is_owner: false, day: TODAY, seconds: 7200, turns: 9 },
    { slack_team: "T1", slack_user: "U0LAWRENCE", sender_is_owner: false, day: TODAY, seconds: 2460, turns: 4 },
    { slack_team: "T1", slack_user: "U0GUEST", sender_is_owner: false, day: TODAY, seconds: 40, turns: 1 },
    { slack_team: "T1", slack_user: "U0AUSTIN", sender_is_owner: false, day: "2026-11-25", seconds: 3600, turns: 3 },
  ],
};

type Props = { awake: SlackAwake; busy?: boolean };

function SlackAwakeGallery({ awake, busy }: Props) {
  installCatalog(table);
  const [value, setValue] = useState(awake);
  useEffect(() => {
    const previous = document.documentElement.dataset.settingsLook;
    document.documentElement.dataset.settingsLook = "refined";
    return () => {
      if (previous === undefined) delete document.documentElement.dataset.settingsLook;
      else document.documentElement.dataset.settingsLook = previous;
    };
  }, []);
  return (
    <div className="settings" style={{ display: "block" }}>
      <main className="content">
        <div className="column">
          <div className="accounts">
            <SlackAwakeCard
              awake={value}
              today={TODAY}
              names={names}
              busy={busy}
              setAllowance={(seconds) => setValue({ ...value, allowance_seconds: seconds ?? value.default_seconds })}
            />
          </div>
        </div>
      </main>
    </div>
  );
}

export default componentEntry<Props>({
  id: "settings.slack-awake",
  title: "Slack awake time (allowance, who spent it)",
  area: "Settings",
  height: 420,
  widths: { narrow: 360, normal: 640, wide: 900 },
  covers: ["pages/settings/components/SlackAwakeCard.tsx"],
  load: async () => SlackAwakeGallery,
  styles: () => import("./page.css"),
  variants: {
    "busy-day": { props: { awake: busyDay } },
    quiet: { props: { awake: base } },
    "owner-only": { props: { awake: { ...busyDay, allowance_seconds: 0 } } },
    "custom-4h": { props: { awake: { ...busyDay, allowance_seconds: 14400 } } },
    "off-preset-90min": { props: { awake: { ...busyDay, allowance_seconds: 5400 } } },
    saving: { props: { awake: busyDay, busy: true } },
  },
});
