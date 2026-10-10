// l10n-allow-file: gallery fixtures, not shipped UI.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { DictationButton } from "./DictationButton";
import { deliverDictation, type Dictation } from "./dictation";
import type { DictationUpdate } from "./dictationText";
import { DictationNotice } from "./DictationNotice";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "./shortcuts";

type Props = {
  initialState: Dictation["state"];
  initialNotice: DictationUpdate | null;
};

const update = (state: DictationUpdate["state"], extra: Partial<DictationUpdate> = {}): DictationUpdate => ({
  state,
  text: state === "listening" ? "gallery words" : "",
  level: state === "listening" ? 0.72 : 0,
  cancelled: false,
  ...extra,
});

function GalleryDictation({ initialState, initialNotice }: Props) {
  const [state, setState] = useState<Dictation["state"]>(initialState);
  const [notice, setNotice] = useState<DictationUpdate | null>(initialNotice);
  const [settingsOpened, setSettingsOpened] = useState(false);

  useEffect(() => {
    deliverDictation(update(state));
  }, [state]);

  const dictation: Dictation = {
    state,
    notice,
    toggle() {
      setState((current) => (current === "idle" ? "listening" : "idle"));
    },
    cancel() {
      setState("idle");
    },
    openSettings() {
      setSettingsOpened(true);
    },
    dismiss() {
      setNotice(null);
    },
  };

  return (
    <ShortcutsContext.Provider value={{ [SHORTCUT_ACTIONS.toggleDictation]: "⇧⌘D" }}>
      <div className="acpmux-shell" data-dictation-fixture>
        <div className="acpmux-dictation-notice-host">
          <DictationNotice dictation={dictation} />
        </div>
        <div className="acpmux-composer">
          <div className="acpmux-composer-box">
            <div className="acpmux-composer-bar">
              <span className="acpmux-chips-spacer" />
              <div className="acpmux-composer-actions">
                <DictationButton dictation={dictation} />
              </div>
            </div>
          </div>
        </div>
        {settingsOpened ? <output data-settings-receipt>System Settings requested</output> : null}
      </div>
    </ShortcutsContext.Provider>
  );
}

const start: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Dictate" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Stop dictation" }).getAttribute("aria-pressed") === "true");
};

const stop: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Stop dictation" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Dictate" }).getAttribute("aria-pressed") === "false");
};

const permission: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open voice permissions" });
  await ctx.waitFor(() => ctx.document.querySelector("[data-settings-receipt]") !== null);
  await ctx.click({ role: "button", name: "Dismiss" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="alert"]') === null);
};

export default componentEntry<Props>({
  id: "agent-pane.dictation",
  title: "Composer dictation",
  area: "Agent pane",
  height: 180,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-dictation-fixture]" }],
  covers: [
    "agent-session/acpmux/DictationButton.tsx#DictationButton",
    "agent-session/acpmux/DictationLevelMeter.tsx#DictationLevelMeter",
    "agent-session/acpmux/DictationNotice.tsx#DictationNotice",
  ],
  styles: () => import("./styles.css"),
  load: async () => GalleryDictation,
  variants: {
    idle: { props: { initialState: "idle", initialNotice: null } },
    listening: { props: { initialState: "listening", initialNotice: null } },
    finalizing: { props: { initialState: "finalizing", initialNotice: null } },
    start: {
      props: { initialState: "idle", initialNotice: null },
      play: start,
      note: "The mic keeps the composer focused while it switches to the live level meter.",
    },
    stop: {
      props: { initialState: "listening", initialNotice: null },
      play: stop,
    },
    denied: {
      props: {
        initialState: "idle",
        initialNotice: {
          ...update("denied"),
          permission: "microphone",
          message: "Microphone access is blocked for cmux.",
          settingsLabel: "Open voice permissions",
        },
      },
      play: permission,
      note: "A denied microphone keeps the explanation above the composer with direct recovery and dismissal.",
    },
    failed: {
      props: {
        initialState: "idle",
        initialNotice: { ...update("failed"), message: "Dictation could not start." },
      },
    },
  },
});
