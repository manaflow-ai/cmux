// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { useEffect, useState } from "react";
import { SlackAwakeCard, type SlackAwakeLook } from "./components/SlackAwakeCard";
import type { SlackAwake, SlackNames } from "./slackAwake";

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

type Props = { awake: SlackAwake; look: SlackAwakeLook };

function SlackAwakeGallery({ awake, look }: Props) {
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
              look={look}
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
    "stepper-busy-day": { props: { awake: busyDay, look: "stepper" } },
    "presets-busy-day": { props: { awake: busyDay, look: "presets" } },
    "slider-busy-day": { props: { awake: busyDay, look: "slider" } },
    "stepper-quiet": { props: { awake: base, look: "stepper" } },
    "presets-owner-only": { props: { awake: { ...busyDay, allowance_seconds: 0 }, look: "presets" } },
    "slider-custom-4h": { props: { awake: { ...busyDay, allowance_seconds: 14400 }, look: "slider" } },
  },
});
