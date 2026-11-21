import { useRef } from "react";
import { useT } from "./i18n";
import { type MachineShareProps, useMachineShare } from "./MachineShareAction";
import type { AcpmuxSnapshot } from "./model";
import { CloudSignIn } from "./conversation/CloudSignIn";
import { ErrorDetails } from "./conversation/ErrorDetails";
import type { CloudSignIn as CloudSignInActions } from "./cloudAgentLogin";
import { startFailureView } from "./startFailure";
import { signInRoute, startRefusalAction, type StartRefusalAction } from "./startRefusal";

/// What the card's one-click way out asks for: a refusal's own (startRefusal.ts), or Install for an
/// agent that is not on the machine (startFailure.ts). `signIn` reaches `onAction` only for a chat
/// on this Mac (its login in a terminal tab); a chat elsewhere signs in inside the card.
export type SwitchNoticeAction = StartRefusalAction | "install";

/// A harness switch's line above the composer (harnessSwitch.ts). Starting draws nothing here:
/// a prompt held behind it reads as sent with Thinking under it, and the composer stays usable,
/// its Stop taking the prompt back (Leo, 2026-11-01).
/// Failed says why, with Retry; the prompts it held are back in the composer. Deferred says the
/// pick waits for the next prompt while the current reply keeps streaming. A refusal with a way out
/// (startRefusal.ts) offers it in one click beside Retry: New Cloud Machine, Choose Folder, or the
/// agent's sign-in. A teammate's machine also offers Share with Me, then Ask the Owner
/// (MachineShareAction.tsx).
/// An agent that is not signed in on the machine (hq#11225) is named ("Cursor isn't signed in on
/// this machine."), and its sign-in leads: on another machine the machine's own sign-in card
/// (CloudSignIn.tsx: Sign in to Cursor, Grok's code, Gemini's key) inside this card, on this Mac
/// Sign in to <agent>, its login in a terminal tab (no ellipsis: it runs at once, as Install does).
/// Retry then starts it signed in, and stays beside the sign-in while the card shows its page,
/// code or key (styles.css). A machine with no sign-in for it says to sign it in on this machine,
/// the chat's, as its first line names it.
/// The sentence is always plain words (startFailure.ts): an agent that is not installed says so and
/// offers Install, other failures read as a failed turn's do, and the agent's raw words wait under
/// Details with Copy error.
export function SwitchNotice({
  switching,
  onRetry,
  onShared,
  onAction,
  share,
  installs = true,
  agentSignIn,
  runsLogin = false,
}: {
  switching: AcpmuxSnapshot["switching"];
  onRetry(): void;
  /// Share with Me went through: start again and resend the prompt the refusal handed back.
  onShared?(): void;
  onAction?(action: SwitchNoticeAction): void;
  share?: MachineShareProps;
  /// Whether Install may be offered: the installer runs in a terminal tab of this Mac, so a chat on
  /// another machine never offers it (its sentence still says the agent is not installed there).
  installs?: boolean;
  /// The refused agent's sign-in on the chat's machine (cloudAgentLogin.ts), for a chat elsewhere.
  agentSignIn?: CloudSignInActions;
  /// A chat on this Mac whose refused agent has a login command: Sign in runs it (`onAction("signIn")`).
  runsLogin?: boolean;
}) {
  const t = useT();
  const actionsRef = useRef<HTMLDivElement>(null);
  const machineShare = useMachineShare(share, switching?.phase === "failed" ? switching : undefined, onRetry, onShared);
  // A switch picked mid-turn (`deferred`) says nothing: the agent chip already shows the pick.
  if (!switching || switching.phase !== "failed") return null;
  const view = startFailureView(t, switching);
  const refusal = startRefusalAction(switching.code);
  const signIn =
    refusal === "signIn"
      ? signInRoute({ elsewhere: !installs, card: agentSignIn !== undefined, login: runsLogin })
      : undefined;
  const action: SwitchNoticeAction | undefined =
    refusal === "signIn"
      ? signIn === "terminal"
        ? "signIn"
        : undefined
      : (refusal ?? (installs && view.install ? "install" : undefined));
  const leads = action !== undefined || signIn === "card";
  const hint = refusal === "signIn" && signIn === undefined && !installs ? t("switch.signInElsewhere") : undefined;
  return (
    <div className="acpmux-host-error acpmux-switch-failed" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">{view.sentence}</p>
        {(machineShare.line ?? hint) && <p className="acpmux-host-error-hint">{machineShare.line ?? hint}</p>}
        <div className="acpmux-host-error-actions" ref={actionsRef}>
          {machineShare.button}
          {signIn === "card" && agentSignIn && (
            <CloudSignIn signIn={agentSignIn} rowId={undefined} prompt={undefined} actionsRef={actionsRef} />
          )}
          {action && onAction && (
            <button
              type="button"
              data-secondary={machineShare.button ? "" : undefined}
              onClick={() => onAction(action)}
            >
              {action === "signIn"
                ? t("switch.action.signInTo", { harness: switching.name })
                : t(
                    action === "install"
                      ? "switch.action.install"
                      : action === "newCloudMachine"
                        ? "switch.action.newCloudMachine"
                        : "switch.action.chooseFolder",
                  )}
            </button>
          )}
          <button
            type="button"
            data-secondary={leads && (onAction || signIn === "card") ? "" : undefined}
            onClick={machineShare.retry ?? onRetry}
          >
            {t("switch.retry")}
          </button>
        </div>
        {view.detail && <ErrorDetails text={view.detail} className="acpmux-host-error-details" />}
      </div>
    </div>
  );
}
