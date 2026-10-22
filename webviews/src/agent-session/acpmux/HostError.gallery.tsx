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
};

function GalleryHostError({ message, hint, action, initialRetrying, withRetry }: Props) {
  const [retrying, setRetrying] = useState(initialRetrying);
  return (
    <div className="acpmux-shell" data-host-error-fixture>
      <HostError
        message={message}
        hint={hint}
        action={action}
        retrying={retrying}
        onRetry={withRetry ? () => setRetrying(true) : undefined}
      />
    </div>
  );
}

const retry: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Retry" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Retrying…" }).getAttribute("disabled") !== null);
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
    "remote-unreached": {
      props: {
        message:
          "cmux cannot find mini-1 on your network. Turn Tailscale on, on this Mac and on mini-1, and sign both in to the same tailnet.",
        initialRetrying: false,
        withRetry: true,
      },
      note: "A chat on another Mac that cannot be reached when it opens (Leo 2026-10-21): the way it failed and its fix, never “acpmux did not answer in time”.",
    },
    "remote-offline": {
      props: {
        message: "mini-1 is offline. Wake mini-1, and check that Tailscale is on there.",
        initialRetrying: false,
        withRetry: true,
      },
      note: "The tailnet lists the chat's machine as offline.",
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
  },
});
