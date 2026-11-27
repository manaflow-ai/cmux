import { useEffect } from "react";
import { Button } from "../../ui/Button";
import { callNative } from "./callNative";
import { StopIcon } from "./ComposerPickers";
import { useT } from "./i18n";
import { tooltipProps } from "./shortcuts";
import { useVoiceState, voiceActive, type VoiceState } from "./voice";
import "./voice.css";

export type VoiceCommand = "voice.toggle" | "voice.cancel" | "voice.skip" | "voice.restart";
type Send = (command: VoiceCommand) => void;
const send: Send = (command) => {
  void callNative(command).catch(() => {});
};

/** The voice control stays to the left of the dictation mic; Send keeps its own slot. */
export function VoiceButton({ state, command = send }: { state: VoiceState; command?: Send }) {
  const t = useT();
  const active = voiceActive(state.state);
  useEffect(() => {
    if (!active) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.isComposing || event.keyCode === 229) return;
      event.preventDefault();
      event.stopPropagation();
      command("voice.cancel");
    };
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [active, command]);
  if (!state.enabled && !active) return null;
  const label = t(active ? "voice.stop" : "voice.start");
  return (
    <Button
      bare
      type="button"
      className="acpmux-mic acpmux-voice-button"
      data-state={state.state}
      aria-label={label}
      aria-pressed={active}
      aria-busy={state.state === "connecting" || undefined}
      {...tooltipProps(label, undefined)}
      onMouseDown={(event) => event.preventDefault()}
      onClick={() => command(active ? "voice.cancel" : "voice.toggle")}
    >
      {active ? (
        <StopIcon />
      ) : (
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <path d="M2 6v4M5 3v10M8 1v14M11 4v8M14 6v4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        </svg>
      )}
    </Button>
  );
}

export function VoiceControl() {
  return <VoiceButton state={useVoiceState()} />;
}

/** Host-localized status and controls occupy the existing quiet footer, without another bar. */
export function VoiceStatusView({ state, command = send }: { state: VoiceState; command?: Send }) {
  const t = useT();
  if (state.state === "idle" && !state.message && !state.restartRequired) return null;
  return (
    <span className="acpmux-voice-status" data-state={state.state}>
      <span className="acpmux-voice-dot" aria-hidden="true" />
      <span role={state.state === "error" ? "alert" : "status"} className="acpmux-voice-status-text">
        {state.message}
      </span>
      {state.state === "speaking" && (
        <Button bare onClick={() => command("voice.skip")}>
          {t("voice.skip")}
        </Button>
      )}
      {state.restartRequired && (
        <Button bare onClick={() => command("voice.restart")}>
          {t("voice.restart")}
        </Button>
      )}
    </span>
  );
}
export function VoiceStatus() {
  return <VoiceStatusView state={useVoiceState()} />;
}
