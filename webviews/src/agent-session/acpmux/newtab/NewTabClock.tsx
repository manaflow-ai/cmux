// The New Tab clock (`tabs.newTabClock.*`): a large stylized time over the composer, with the date
// over it, as the iOS 26 Lock Screen draws them, in a font, weight and color the person picks (Leo,
// 2026-11-16: "idk why you guys couldn't just add an aesthetic time thing like the ios home screen
// whatever customizer"). It sits in the room over the composer (screen.css `.nt-above-room`) and
// never replaces or covers it. Off by default.
import { useEffect, useState } from "react";
import { clockDate, clockTime, msToNextMinute, type NewTabClockStyle } from "./clockModel";
import "./clock.css";

type Props = NewTabClockStyle & {
  /// Tests and the gallery hold the time still.
  now?: number;
  locale?: string;
};

export function NewTabClock({ font, weight, color, date, now: fixed, locale }: Props) {
  const [ticked, setTicked] = useState(() => Date.now());
  useEffect(() => {
    if (fixed !== undefined) return;
    // One timer at a time, to the next minute; it ends with the page (its stop condition: unmount).
    let timer: ReturnType<typeof setTimeout>;
    const tick = () => {
      const at = Date.now();
      setTicked(at);
      timer = setTimeout(tick, msToNextMinute(at));
    };
    timer = setTimeout(tick, msToNextMinute(Date.now()));
    return () => clearTimeout(timer);
  }, [fixed]);
  const at = new Date(fixed ?? ticked);
  return (
    <div className="nt-clock" data-font={font} data-weight={weight} data-color={color}>
      {date && <div className="nt-clock-date">{clockDate(at, locale)}</div>}
      <time className="nt-clock-time" dateTime={at.toISOString()}>
        {clockTime(at, locale)}
      </time>
    </div>
  );
}
