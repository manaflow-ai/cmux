// l10n-allow-file: gallery drafts, machine names and host words, not shipped copy.
//
// The composer while a new chat starts in Cloud (App.tsx `cloudStarting`, cloudStartProgress.ts
// `cloudStartLocksComposer`): locked while the host answers (this tab closes once the chat opens on
// the machine), the person's again once the start stalls (no word from the host for
// CLOUD_START_STALL_MS) or fails. Leo, 2026-11-09: "I can't click into the composer at all".
import { useLayoutEffect, useRef } from "react";
import { componentEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { ComposerHandle } from "./Composer";
import { cloudStartLocksComposer, type CloudStartProgress } from "./cloudStartProgress";

type State = "starting" | "copying" | "stalled" | "failed" | "signing-in";
type Props = { state: State };

const task = "Run the sidebar tests and fix what fails.";
const begun: CloudStartProgress = { key: "gallery", task, state: "starting", folder: "paint" };
const known = { machine: "paint-dev", size: "4 CPU · 16 GB" } as const;
const starts: Record<State, CloudStartProgress> = {
  starting: { ...begun, step: "machine", ...known },
  copying: { ...begun, step: "folder", ...known },
  stalled: { ...begun, step: "machine", ...known, stalled: true },
  failed: {
    ...begun,
    step: "folder",
    ...known,
    state: "failed",
    code: "cloud_start_failed",
    retryable: true,
    message: "Couldn't copy paint to paint-dev: the machine stopped answering.",
  },
  "signing-in": { ...begun, signingIn: true },
};
/// What the composer holds: the sent prompt while it is out; after a stall the person typed on.
const drafts: Record<State, string> = {
  starting: task,
  copying: task,
  stalled: `${task} Also check the dock.`,
  failed: task,
  "signing-in": task,
};

export default componentEntry<Props>({
  id: "agent-pane.composer-cloud-start",
  title: "Composer during a Cloud start",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 400, normal: 640, wide: 860 },
  covers: ["agent-session/acpmux/Composer.tsx#Composer", "agent-session/acpmux/CloudStartView.tsx"],
  keywords: ["cloud", "start", "stuck", "stalled", "locked", "composer"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: async () => {
    const [{ Composer }, { CloudStartView }] = await Promise.all([import("./Composer"), import("./CloudStartView")]);
    return function GalleryComposerCloudStart({ state }: Props) {
      const handle = useRef<ComposerHandle>(null);
      useLayoutEffect(() => {
        handle.current?.restore(drafts[state], []);
      }, [state]);
      const snapshot = noChat([], {});
      const start = starts[state];
      return (
        <div className="acpmux-shell" style={{ display: "block", padding: "var(--space-4)" }}>
          <CloudStartView start={start} bubble onRetry={() => {}} />
          <Composer
            handle={handle}
            snapshot={snapshot}
            locked={cloudStartLocksComposer(start)}
            chips={() => null}
            onSend={() => false}
            onStop={() => {}}
            onProject={() => {}}
            onNewChat={() => {}}
            localName="studio"
            projectChoices={[{ cwd: "/demo/paint", label: "paint" }]}
          />
        </div>
      );
    };
  },
  variants: {
    starting: {
      props: { state: "starting" },
      note: "Just sent: the composer holds the sent prompt and takes no input while the host gets a machine.",
    },
    copying: {
      props: { state: "copying" },
      note: "The folder copies: progress keeps coming, so the composer stays locked.",
    },
    stalled: {
      props: { state: "stalled" },
      note: "No word from the host for five minutes: the card says where it stopped, and the person types again.",
    },
    failed: {
      props: { state: "failed" },
      note: "The start failed: the host's words and Retry, and the prompt is back in an unlocked composer.",
    },
    "signing-in": {
      props: { state: "signing-in" },
      note: "Waiting on the browser sign-in: the person is acting, so no stall is counted and the box stays locked.",
    },
  },
});
