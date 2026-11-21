// l10n-allow-file: gallery drafts, machine names and host words, not shipped copy.
//
// The composer while a new chat starts in Cloud (App.tsx `cloudStarting`): open the whole time, its
// Send waiting until the start ends (this tab closes once the chat opens on the machine, and what was
// typed meanwhile seeds that chat's composer). A start with no word from the host for
// CLOUD_START_STALL_MS stalls: the card says where it stopped. Leo, 2026-11-09: "I can't click into
// the composer at all".
import { useLayoutEffect, useRef } from "react";
import { componentEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { ComposerHandle } from "./Composer";
import type { CloudStartProgress } from "./cloudStartProgress";

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
/// What the composer holds: the Send took the prompt out (it shows as the message), so only what
/// the person typed since; a failed start puts the prompt back in front of it.
const drafts: Record<State, string> = {
  starting: "",
  copying: "",
  stalled: "Also check the dock.",
  failed: task,
  "signing-in": "",
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
            // App.tsx `cloudStarting` and `cloudSendHeld`: typing stays open, Send waits while the
            // start is out, stalled too.
            cloudStarting={start.state === "starting"}
            blockSend={start.state === "starting"}
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
      note: "Just sent: the prompt shows as the message, and the composer is open and empty while the host gets a machine; Send waits.",
    },
    copying: {
      props: { state: "copying" },
      note: "The folder copies: progress keeps coming, and the composer stays open with Send waiting.",
    },
    stalled: {
      props: { state: "stalled" },
      note: "No word from the host for five minutes: the card says where it stopped; what the person typed stays, and Send waits for the start to end.",
    },
    failed: {
      props: { state: "failed" },
      note: "The start failed: the host's words and Retry, and the prompt is back in the composer.",
    },
    "signing-in": {
      props: { state: "signing-in" },
      note: "Waiting on the browser sign-in: the person is acting, so no stall is counted; the composer stays open.",
    },
  },
});
