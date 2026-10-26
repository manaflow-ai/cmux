// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { HostError } from "./HostError";

type Props = {
  message: string;
  hint?: string | null;
  action?: string;
  initialRetrying: boolean;
  withRetry: boolean;
  withRestart?: boolean;
};

function GalleryHostError({ message, hint, action, initialRetrying, withRetry, withRestart }: Props) {
  const [retrying, setRetrying] = useState(initialRetrying);
  const [restarting, setRestarting] = useState(false);
  return (
    <div className="acpmux-shell" data-host-error-fixture>
      <HostError
        message={message}
        hint={hint}
        action={action}
        retrying={retrying}
        onRetry={withRetry ? () => setRetrying(true) : undefined}
        restarting={restarting}
        onRestart={withRestart ? () => setRestarting(true) : undefined}
      />
    </div>
  );
}

const retry: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Retry" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Retrying…" }).getAttribute("disabled") !== null);
};

const restart: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Restart acpmux" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Restarting acpmux…" }).getAttribute("disabled") !== null);
};

const enable: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Enable Claude Code" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Enable Claude Code" }).getAttribute("disabled") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.host-error",
  title: "Agent host error",
  area: "Agent pane",
  height: 210,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-host-error-fixture]" }],
  covers: ["agent-session/acpmux/HostError.tsx#HostError"],
  styles: () => import("./styles.css"),
  load: async () => GalleryHostError,
  variants: {
    automatic: {
      props: {
        message: "The agent host is unavailable.",
        initialRetrying: false,
        withRetry: false,
      },
      note: "When no manual action is available, the card explains that cmux keeps retrying while the prompt stays put.",
    },
    retry: {
      props: {
        message: "The agent host is unavailable.",
        hint: null,
        initialRetrying: false,
        withRetry: true,
      },
      play: retry,
    },
    retrying: {
      props: {
        message: "Connecting to the agent host…",
        initialRetrying: true,
        withRetry: true,
      },
    },
    enable: {
      props: {
        message: "Claude Code is not enabled for this folder.",
        hint: "Enable the harness to continue this chat.",
        action: "Enable Claude Code",
        initialRetrying: false,
        withRetry: true,
      },
      play: enable,
      note: "Folder harness setup uses the same error card with a concrete action label.",
    },
    restart: {
      props: {
        message: "acpmux belongs to cmux NIGHTLY, and this build may not use it. Quit that app, then try again.",
        initialRetrying: false,
        withRetry: true,
        withRestart: true,
      },
      play: restart,
      note: "Another binary's acpmux holds this app's socket: Restart acpmux replaces it with this app's own.",
    },
    "restart-unnamed": {
      props: {
        message: "Another acpmux service is using this socket. It will reconnect when that service is ready.",
        initialRetrying: false,
        withRetry: true,
        withRestart: true,
      },
      note: "A refusal whose holder is no app bundle offers the same Restart acpmux beside Retry.",
    },
  },
});
