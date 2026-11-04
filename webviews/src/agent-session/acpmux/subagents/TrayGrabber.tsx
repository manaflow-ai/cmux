// The grabber that tucks the running tray (the composer hat) away and brings it back. Leo,
// 2026-11-04: "Some people might want to tuck away the composer hat ... the collapse view is still
// one line. It's like, okay, well, what if you wanted to collapse that one line? ... at the top of
// the hat, there's some sort of little thing that's like, I don't know, like a special kind of
// chevron, I guess. And it's like, if you hover around that range, when it's completely almost like,
// yeah, hidden, then you can hover around that, the top of the composer, and then you can click that
// to like unleash the hat or whatever."
//
// Three states: open (the full list), folded (its one header line) and tucked (hidden). The grabber
// is a small pill on the top edge, of the tray while it shows and of the composer while it is tucked,
// drawn while the pointer is in its band (or it has focus). On a showing tray a click tucks it.
// Tucked, a click brings it back folded, and an Option-click brings it back open. Tucked, the pill
// stays drawn while work runs, with how many things run, and draws a dot when an agent waits on the
// person: tucking hides noise, never a question. Its place on the edge is trayGrabber.experiment.ts.
// The tucked state is the setting `agentPane.display.trayTucked` (chatDisplay.ts TRAY_TUCKED_KEY), so
// the command palette, the `cmux settings` CLI and the MCP tools tuck and show it too.
import type { MouseEvent } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { trayGrabberLook } from "./trayGrabber.experiment";
import "./TrayGrabber.css";

export type TrayGrabberSide = keyof typeof trayGrabberLook.arms;

export function TrayGrabber({
  tucked,
  side,
  running = 0,
  waiting = 0,
  onToggle,
}: {
  /// The tray is tucked away: the grabber brings it back.
  tucked: boolean;
  side: TrayGrabberSide;
  /// How many things run (subagents, commands, started chats), shown while tucked.
  running?: number;
  /// How many wait on the person, shown as a dot while tucked.
  waiting?: number;
  /// A click: `open` when it brings the tray back open (Option-click), else folded.
  onToggle: (open: boolean) => void;
}) {
  const t = useT();
  const label = tucked
    ? [
        t("tray.grabber.show"),
        running > 0 ? t("tray.grabber.running", { n: running }) : undefined,
        waiting > 0 ? t("tray.grabber.waiting", { n: waiting }) : undefined,
      ]
        .filter(Boolean)
        .join(" · ")
    : t("tray.grabber.tuck");
  return (
    <button
      type="button"
      className="acpmux-tray-grabber"
      data-side={side}
      data-tucked={tucked || undefined}
      // Tucked with work running or a question waiting, the pill stays drawn at rest.
      data-live={(tucked && (running > 0 || waiting > 0)) || undefined}
      data-waiting={(tucked && waiting > 0) || undefined}
      aria-label={label}
      title={tucked ? t("tray.grabber.showHint") : label}
      onClick={(event: MouseEvent<HTMLButtonElement>) => onToggle(event.altKey)}
    >
      <span className="acpmux-tray-grabber__pill" aria-hidden="true">
        {/* icon-scale-allow: the pill is 8 to 12px tall, so its chevron is the 10px caption glyph */}
        <Icon name="disclosure.expanded" size={10} row />
        {tucked && running > 0 && <span className="acpmux-tray-grabber__count">{running}</span>}
        {tucked && waiting > 0 && <span className="acpmux-tray-grabber__dot" />}
      </span>
    </button>
  );
}
