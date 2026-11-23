import { useMemo } from "react";
import { callNative } from "../callNative";
import { sayActionRefusal } from "../actionRefusal";
import { useHeaderState } from "../header/headerState";
import { translate } from "../i18n";
import type { PlaceMode } from "./placeModel";

/// What the place controls ask of the app. Drawing only: the app decides (chatPlace.set moves a local
/// chat to its Cloud VM, brings a Cloud one back, or sets Auto; the refusal's reason comes back as
/// a toast).
export interface PlaceActions {
  setMode(mode: PlaceMode): void;
  cancel(): void;
  retry(): void;
}

export interface EvacuateActions {
  /// Every chat on this Mac, or just `sessions`.
  evacuate(sessions?: readonly string[]): void;
  /// Stop the running Evacuate; chats already in Cloud stay there.
  cancelEvacuate(): void;
  /// A chat's place from the chat list.
  setMode(session: string, mode: PlaceMode): void;
}

const refusal = (say: ((text: string) => void) | undefined) =>
  say
    ? sayActionRefusal(say, () => translate("composer.offloadNotRun", { action: translate("place.label") }))
    : () => undefined;

/// The calls bound to `session`: the app runs them only while its tab still shows that chat.
export function placeActions(session: string, say?: (text: string) => void): PlaceActions {
  const fail = refusal(say);
  const run = (payload: Record<string, unknown>) => void callNative("action.run", { ...payload, session }).catch(fail);
  return {
    setMode: (mode) => run({ id: "chatPlace.set", mode }),
    cancel: () => run({ id: "chatMove.cancel" }),
    retry: () => run({ id: "chatMove.retry" }),
  };
}

export function evacuateActions(say?: (text: string) => void): EvacuateActions {
  const fail = refusal(say);
  return {
    evacuate: (sessions) =>
      void callNative("action.run", { id: "cloudEvacuate", ...(sessions ? { sessions: [...sessions] } : {}) }).catch(
        fail,
      ),
    cancelEvacuate: () => void callNative("action.run", { id: "cloudEvacuate.cancel" }).catch(fail),
    setMode: (session, mode) => void callNative("action.run", { id: "chatPlace.set", mode, session }).catch(fail),
  };
}

/// The chat's place from `pane.tabState`, and its actions.
export function usePlace(session: string | undefined, say?: (text: string) => void) {
  const { place, evacuate } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say) : undefined), [session, say]);
  return { place, evacuate, actions };
}
