// l10n-allow-file: gallery fixtures exercise the view's shipped labels and failure words.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { chat } from "../../gallery/fixtures/acpmux";
import { Composer } from "./Composer";
import { FailedStartRecovery } from "./FailedStartRecovery";
import type { SetupPhase } from "./harnessSetup";
import { MissingHarnessNotice } from "./MissingHarnessNotice";
import { NoticeSlot } from "./NoticeSlot";
import type { StartRecoveryLook } from "./StartRecovery";
import type { StartRecoveryReason } from "./startRecoveryReason";

/// The chat that failed to start: nothing sent, the typed message back in the composer.
const fresh = chat([], { title: "New chat", harness: "claude", model: "default" });
const NoChips = () => null;
/// The same chat after the person picked Codex in the composer.
const picked = chat([], { title: "New chat", harness: "codex", model: "default" });

const SIGNED_OUT = {
  harness: "claude",
  name: "Claude Code",
  error: "Invalid API key · Please run /login",
  code: "auth_required",
};
const OFFLINE = {
  harness: "codex",
  name: "Codex",
  error: "stream error: connect ECONNREFUSED 104.18.32.47:443 (fetch failed)",
};

type Props = {
  reason: StartRecoveryReason;
  look?: StartRecoveryLook;
  /// The missing agent's install step, when one runs.
  phase?: SetupPhase;
  /// Signed out with no login cmux knows here: Try Again leads.
  noLogin?: boolean;
  /// The picked agent changed after the failure: the view still names the agent that failed.
  stale?: boolean;
};

function GalleryStartRecovery({ reason, look = "side", phase, noLogin = false, stale = false }: Props) {
  const [clicked, setClicked] = useState<string>();
  const [shown, setShown] = useState(true);
  const dismiss = () => {
    setClicked("dismiss");
    setShown(false);
  };
  return (
    <section
      className="acpmux-shell start-recovery-gallery"
      aria-label="Start recovery"
      data-recovery-clicked={clicked ?? ""}
    >
      <div className="acpmux-main">
        <div className="acpmux-stage" />
        <div className="acpmux-dock">
          <NoticeSlot>
            {shown &&
              (reason === "missing-harness" ? (
                <MissingHarnessNotice
                  name="Claude Code"
                  {...(phase ? { phase } : {})}
                  installable
                  look={look}
                  onInstall={() => setClicked("install")}
                  onSignIn={() => setClicked("signIn")}
                  onDismiss={dismiss}
                />
              ) : (
                <FailedStartRecovery
                  start={reason === "signed-out" ? SIGNED_OUT : OFFLINE}
                  reason={reason}
                  look={look}
                  {...(noLogin ? {} : { onSignIn: () => setClicked("signIn") })}
                  onRetry={() => setClicked("retry")}
                  onDismiss={dismiss}
                />
              ))}
          </NoticeSlot>
          <Composer snapshot={stale ? picked : fresh} chips={NoChips} onSend={() => true} onStop={() => undefined} />
        </div>
      </div>
    </section>
  );
}

const clickPrimary: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-start-recovery .acpmux-host-error-actions button:first-child" });
  await ctx.waitFor(
    () => ctx.document.querySelector('[data-recovery-clicked]:not([data-recovery-clicked=""])') !== null,
  );
};

const escapeDismisses: Play = async (ctx) => {
  await ctx.focus({ selector: '[data-recovery-action="dismiss"]' });
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector('[data-recovery-clicked="dismiss"]') !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.start-recovery",
  title: "Start recovery",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 340, normal: 560, wide: 760 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/StartRecovery.tsx#StartRecovery",
    "agent-session/acpmux/FailedStartRecovery.tsx#FailedStartRecovery",
  ],
  styles: () => import("./styles.css"),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Each recovery step swaps words and buttons inside one view; the composer never moves.",
    },
  },
  load: async () => GalleryStartRecovery,
  variants: {
    // Chosen: a small picture beside the sentence keeps the view as short as the other notices.
    "look-side": {
      note: "Shipped look. Picture at the side, one sentence, Install and Dismiss.",
      props: { reason: "missing-harness", look: "side" },
      play: clickPrimary,
    },
    "look-centered": {
      note: "Candidate: picture above, centered text. Friendlier, but twice as tall above the composer.",
      props: { reason: "missing-harness", look: "centered" },
    },
    "look-card": {
      note: "Candidate: a wide card with a larger picture. Reads as an empty state, not a notice; cramped when narrow.",
      props: { reason: "missing-harness", look: "card" },
    },
    "signed-out": {
      note: "Signed out at start: Sign In opens the agent's own login; Try Again starts the chat after.",
      props: { reason: "signed-out" },
      play: clickPrimary,
    },
    "signed-out-no-login": {
      note: "Signed out, no login cmux knows on this machine: Try Again leads.",
      props: { reason: "signed-out", noLogin: true },
    },
    offline: {
      note: "Offline: the plain sentence, the network's words under Details, Try Again; the message stays in the composer.",
      props: { reason: "offline" },
      play: clickPrimary,
    },
    "offline-centered": {
      note: "Candidate look for offline.",
      props: { reason: "offline", look: "centered" },
    },
    keyboard: {
      note: "Escape inside the view dismisses it and focus goes back where it was.",
      props: { reason: "offline" },
      play: escapeDismisses,
    },
    installing: {
      note: "Install running: the spinner trails the sentence and the installer's last line is under it.",
      props: { reason: "missing-harness", phase: { kind: "installing", line: "Downloading Claude Code 2.4.1..." } },
    },
    "action-failed": {
      note: "Install failed: Try Again, the installer's words under Details.",
      props: {
        reason: "missing-harness",
        phase: { kind: "failed", reason: "curl: (6) Could not resolve host: claude.ai" },
      },
    },
    "stale-selection": {
      note: "The composer's agent changed after the failure: the view still names the agent that failed.",
      props: { reason: "signed-out", stale: true },
    },
  },
});
