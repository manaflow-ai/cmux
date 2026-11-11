// The open Chief chat's turn controls (chiefTurn.ts) as the transcript takes them: the message box's
// Stop, Escape, Cmd-. and Continue, and the stop-all toast over it with Restart.
import { useEffect, useMemo, useSyncExternalStore, type ReactNode } from "react";
import type { Strings } from "../../shared/i18n";
import type { PageClient } from "../../shared/pageClient";
import { Notice } from "../../../ui/Notice";
import { ChiefSkills } from "./chiefSkills";
import { ChiefTurn } from "./chiefTurn";
import type { ComposerChief } from "./MessageComposer";

export interface ChiefTurnProps {
  chief?: ComposerChief;
  toast?: ReactNode;
  /** Start now on a queued agent (ChiefTurn.startAgent): a refusal's words show in the toast. */
  startAgent?: (agent: string) => Promise<boolean>;
}

/** `working`: the Chief types or writes its reply in the conversation (HomeHostView: `isChief && typing`).
 * `sequence`: the conversation's newest seq (a new message ends a stop's Continue). Not a Chief chat:
 * nothing. */
export function useChiefTurn(
  host: PageClient | null,
  conversation: string,
  isChief: boolean,
  working: boolean,
  sequence: number,
  words: Strings,
): ChiefTurnProps {
  const turn = useMemo(() => new ChiefTurn(host, conversation, words), [host, conversation, words]);
  useEffect(() => () => turn.dispose(), [turn]);
  // `/` in the message box lists the Chief's skills (chiefSkills.ts), read on the first `/`.
  const skills = useMemo(() => (host && isChief ? new ChiefSkills(host, conversation) : undefined), [host, conversation, isChief]);
  useEffect(() => () => skills?.dispose(), [skills]);
  useEffect(() => turn.update(isChief && working, sequence), [turn, isChief, working, sequence]);
  const view = useSyncExternalStore(turn.subscribe, turn.getSnapshot);
  const startAgent = useMemo(() => (host ? (agent: string) => turn.startAgent(agent) : undefined), [host, turn]);
  if (!isChief) return {};
  const toast = view.toast;
  return {
    chief: {
      working: view.working,
      continueAvailable: view.continueAvailable,
      onStop: (all) => turn.stop(all),
      onContinue: () => turn.continueTurn(),
      ...(skills ? { skills } : {}),
    },
    ...(startAgent ? { startAgent } : {}),
    ...(toast
      ? {
          toast: (
            <div title={toast.detail} data-chief-toast={toast.id}>
              <Notice
                key={toast.id}
                kind="toast"
                placement="stack"
                message={toast.message.split("\n").map((line, index) => (
                  <span key={index} className="mt-toast-line">
                    {line}
                  </span>
                ))}
                actions={
                  toast.restart
                    ? [
                        {
                          id: "restart",
                          label: words.t("home.stopAll.restart"),
                          onSelect: () => turn.restart(toast.restart ?? []),
                        },
                      ]
                    : []
                }
              />
            </div>
          ),
        }
      : {}),
  };
}
