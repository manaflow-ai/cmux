import { useEffect, useMemo, useState } from "react";
import { useNt } from "./strings";

const QUOTES = [
  ["quote.1", "Mark Twain"],
  ["quote.2", "Aristotle"],
  ["quote.3", "Ralph Waldo Emerson"],
  ["quote.4", "Vincent van Gogh"],
] as const;

function dayIndex(now: number): number {
  return Math.floor(now / 86_400_000) % QUOTES.length;
}

export function NewTabExtras({ widgets, now }: { widgets: ReadonlySet<string>; now: number }) {
  const nt = useNt();
  const [elapsed, setElapsed] = useState(0);
  const timerOn = widgets.has("timer");
  useEffect(() => {
    if (!timerOn) return;
    const started = Date.now();
    const update = () => setElapsed(Math.floor((Date.now() - started) / 1000));
    update();
    const id = window.setInterval(update, 1000);
    return () => window.clearInterval(id);
  }, [timerOn]);
  const quote = useMemo(() => QUOTES[dayIndex(now)]!, [now]);
  const hour = new Date(now).getHours();
  const warm = nt(hour < 12 ? "extra.morning" : hour < 18 ? "extra.afternoon" : "extra.evening");
  if (!widgets.has("clock") && !widgets.has("timer") && !widgets.has("warmGreeting") && !widgets.has("quote"))
    return null;
  return (
    <div className="nt-extras" aria-label={nt("extra.widgets")}>
      {widgets.has("warmGreeting") && <div className="nt-extra-warm">{warm}</div>}
      {widgets.has("clock") && (
        <time className="nt-extra-clock" dateTime={new Date(now).toISOString()}>
          {new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(now)}
        </time>
      )}
      {widgets.has("timer") && (
        <div className="nt-extra-timer" role="timer">
          {nt("extra.stopwatch")} {Math.floor(elapsed / 60)}:{String(elapsed % 60).padStart(2, "0")}
        </div>
      )}
      {widgets.has("quote") && (
        <figure className="nt-extra-quote">
          <blockquote>“{nt(quote[0])}”</blockquote>
          <figcaption>— {quote[1]}</figcaption>
        </figure>
      )}
    </div>
  );
}
