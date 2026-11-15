// Try on (cmux-customize `try_on.rs`): a customization applied for a while goes back by itself
// unless the person keeps it, so trying something costs nothing. Leo, 2026-11-14: "the ergonomics
// need to be real good like just ultra braindead". The engine owns the clock and the revert (it
// reverts at the first look after the end time, the app's start included); this bar only shows
// the time left and the two ways out.
import { useCallback, useEffect, useState, type CSSProperties } from "react";
import { Button } from "../../../ui/Button";
import { useSettingsState, useStore } from "../context";
import type { CustomizeTryOn } from "../ops";
import { t } from "../strings";

/** The gallery's three looks; `row` ships. */
export type TryOnLook = "row" | "card" | "pill";

/** `9:05`, `0:42`: whole seconds, rounded up, so it never reads 0:00 before the revert. */
export function timeLeft(ms: number): string {
  const seconds = Math.max(0, Math.ceil(ms / 1000));
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${String(seconds % 60).padStart(2, "0")}`;
}

export function TryOnBar({
  tryOn,
  now,
  look = "row",
  busy = false,
  onKeep,
  onRevert,
}: {
  tryOn: CustomizeTryOn;
  now: number;
  look?: TryOnLook;
  busy?: boolean;
  onKeep: () => void;
  onRevert: () => void;
}) {
  const left = tryOn.expires_ms - now;
  const whole = Math.max(1, tryOn.expires_ms - tryOn.started_ms);
  const meter = { "--try-on-left": String(Math.min(1, Math.max(0, left / whole))) } as CSSProperties;
  return (
    <output className="try-on" data-look={look} data-try-on="" data-enter="top" style={meter}>
      <span className="try-on-text">
        <span className="try-on-title">{t("settingsPage.tryOn.title", tryOn.label)}</span>
        <span className="try-on-left" data-try-on-left="">
          {t("settingsPage.tryOn.left", timeLeft(left))}
        </span>
      </span>
      <Button size="sm" variant="ghost" disabled={busy} onClick={onRevert} data-try-on-revert="">
        {t("settingsPage.tryOn.revert")}
      </Button>
      <Button size="sm" variant="solid" disabled={busy} onClick={onKeep} data-try-on-keep="">
        {t("settingsPage.tryOn.keep")}
      </Button>
      <span className="try-on-meter" aria-hidden="true" />
    </output>
  );
}

/** The bar at the top of Settings while something is tried on. It reads the engine when the page
 * opens or comes back to the front, ticks once a second only while a try-on runs, and reads again
 * at the end time, which is the look that reverts it. */
export function TryOnSlot() {
  const store = useStore();
  const { connected } = useSettingsState();
  const [tryOn, setTryOn] = useState<CustomizeTryOn | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [busy, setBusy] = useState(false);
  const read = useCallback(async () => {
    const next = await store.customize("status");
    setNow(Date.now());
    setTryOn(next);
  }, [store]);
  useEffect(() => {
    if (!connected) return;
    void read();
    const again = () => {
      if (document.visibilityState === "visible") void read();
    };
    window.addEventListener("focus", again);
    document.addEventListener("visibilitychange", again);
    return () => {
      window.removeEventListener("focus", again);
      document.removeEventListener("visibilitychange", again);
    };
  }, [connected, read]);
  // The countdown's tick, with its stop condition: no try-on, or its end time reached.
  useEffect(() => {
    if (!tryOn) return;
    const tick = setInterval(() => {
      const time = Date.now();
      setNow(time);
      if (time >= tryOn.expires_ms) {
        clearInterval(tick);
        void read();
      }
    }, 1000);
    return () => clearInterval(tick);
  }, [tryOn, read]);
  if (!tryOn) return null;
  const run = (verb: "keep" | "revert") => {
    setBusy(true);
    void store
      .customize(verb)
      .then(setTryOn)
      .finally(() => setBusy(false));
  };
  return <TryOnBar tryOn={tryOn} now={now} busy={busy} onKeep={() => run("keep")} onRevert={() => run("revert")} />;
}
