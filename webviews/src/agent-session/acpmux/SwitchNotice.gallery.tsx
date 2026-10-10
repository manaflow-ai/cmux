// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { SwitchNotice } from "./SwitchNotice";

type Props = {
  initialSwitching: AcpmuxSnapshot["switching"];
};

type Switching = NonNullable<AcpmuxSnapshot["switching"]>;

function GallerySwitchNotice({ initialSwitching }: Props) {
  const [retried, setRetried] = useState(false);
  const switching =
    retried && initialSwitching ? { ...initialSwitching, phase: "starting" as const } : initialSwitching;

  return (
    <div data-switch-notice-fixture>
      <SwitchNotice switching={switching} onRetry={() => setRetried(true)} />
      {retried ? <output data-retry-receipt>Retry requested; starting {initialSwitching?.name}</output> : null}
    </div>
  );
}

const retry: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Retry" });
  await ctx.waitFor(() => ctx.document.querySelector("[data-retry-receipt]") !== null);
};

const switching = (phase: Switching["phase"], error?: string): Switching => ({
  harness: "codex",
  name: "Codex",
  phase,
  ...(error ? { error } : {}),
});

export default componentEntry<Props>({
  id: "agent-pane.switch-notice",
  title: "Harness switch notice",
  area: "Agent pane",
  height: 180,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-switch-notice-fixture]" }],
  covers: ["agent-session/acpmux/SwitchNotice.tsx#SwitchNotice"],
  styles: () => import("./styles.css"),
  load: async () => GallerySwitchNotice,
  variants: {
    hidden: { props: { initialSwitching: undefined } },
    starting: {
      props: { initialSwitching: switching("starting") },
      note: "Starting is deliberately quiet: the composer stays usable while the new harness comes up.",
    },
    deferred: {
      props: { initialSwitching: switching("deferred") },
      note: "A deferred pick waits until the current reply finishes.",
    },
    failed: {
      props: { initialSwitching: switching("failed", "The harness did not respond") },
    },
    retry: {
      props: { initialSwitching: switching("failed", "The harness did not respond") },
      play: retry,
      note: "Retry returns to the quiet starting state and keeps the notice above the composer.",
    },
  },
});
