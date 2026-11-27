// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { DictationButton } from "./DictationButton";
import type { Dictation } from "./dictation";
import { VoiceButton, VoiceStatusView, type VoiceCommand } from "./VoiceControls";
import type { VoiceState } from "./voice";

const dictation: Dictation = {
  state: "idle",
  notice: null,
  toggle() {},
  finish() {},
  cancel() {},
  openSettings() {},
  dismiss() {},
};
function GalleryVoice({ initial }: { initial: VoiceState }) {
  const [state, setState] = useState(initial);
  const command = (action: VoiceCommand) =>
    setState(
      action === "voice.cancel"
        ? { state: "idle", enabled: true }
        : { state: "listening", enabled: true, message: "Listening", level: 0.65 },
    );
  return (
    <div className="acpmux-shell" data-voice-fixture>
      <div className="acpmux-composer">
        <div className="ui-glass acpmux-composer-box">
          <div className="acpmux-composer-bar">
            <span className="acpmux-fit-mic">
              <VoiceButton state={state} command={command} />
              <DictationButton dictation={dictation} />
            </span>
          </div>
        </div>
        <div className="acpmux-composer-bar acpmux-composer-foot" data-footer-look="plain">
          <VoiceStatusView state={state} command={command} />
        </div>
      </div>
    </div>
  );
}
export default componentEntry<{ initial: VoiceState }>({
  id: "agent-pane.voice",
  title: "Composer voice mode",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 260, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-voice-fixture]" }],
  covers: [
    "agent-session/acpmux/VoiceControls.tsx#VoiceButton",
    "agent-session/acpmux/VoiceControls.tsx#VoiceStatusView",
  ],
  styles: () => import("./styles.css"),
  load: async () => GalleryVoice,
  variants: {
    disabled: { props: { initial: { state: "idle", enabled: false } } },
    ready: {
      props: { initial: { state: "idle", enabled: true } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Start voice mode" });
        await ctx.waitFor(
          () => ctx.find({ role: "button", name: "Stop voice mode" }).getAttribute("aria-pressed") === "true",
        );
      },
    },
    listening: { props: { initial: { state: "listening", enabled: true, message: "Listening", level: 0.65 } } },
    thinking: { props: { initial: { state: "thinking", enabled: true, message: "Agent is working" } } },
    speaking: {
      props: { initial: { state: "speaking", enabled: true, message: "Speaking" } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Skip reading" });
        await ctx.waitFor(() => ctx.find({ role: "status" }).textContent === "Listening");
      },
    },
    restart: {
      props: {
        initial: { state: "error", enabled: true, message: "Voice mode needs to restart", restartRequired: true },
      },
    },
    denied: { props: { initial: { state: "error", enabled: true, message: "Microphone permission is required" } } },
  },
});
