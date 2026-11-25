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
  /// Bring the evacuated chats (or all Cloud chats; or just `sessions`) back to This Mac.
  bringBack(sessions?: readonly string[]): void;
  /// Stop the running Evacuate; chats already in Cloud stay there.
  cancelEvacuate(): void;
  /// A chat's place from the chat list.
  setMode(session: string, mode: PlaceMode): void;
}

const refusal = (say: ((text: string) => void) | undefined) =>
  say
    ? sayActionRefusal(say, () => translate("composer.offloadNotRun", { action: translate("place.label") }))
    : () => undefined;

/// What only the page knows of what a move carries: the prompts queued behind the turn and an unsent
/// draft. Read when the person picks, so the card's list is what is there then.
export interface PlaceClaims {
  readonly queued: number;
  readonly hasDraft: boolean;
}

/// The calls bound to `session`: the app runs them only while its tab still shows that chat. A place
/// pick and a Retry send `claims()` (chatPlace.set, chatMove.retry take `queued` and `hasDraft`).
export function placeActions(session: string, say?: (text: string) => void, claims?: () => PlaceClaims): PlaceActions {
  const fail = refusal(say);
  const run = (payload: Record<string, unknown>) => void callNative("action.run", { ...payload, session }).catch(fail);
  const carried = () => (claims ? { ...claims() } : {});
  return {
    setMode: (mode) => run({ id: "chatPlace.set", mode, ...carried() }),
    cancel: () => run({ id: "chatMove.cancel" }),
    retry: () => run({ id: "chatMove.retry", ...carried() }),
  };
}

export function evacuateActions(say?: (text: string) => void): EvacuateActions {
  const fail = refusal(say);
  return {
    evacuate: (sessions) =>
      void callNative("action.run", { id: "cloudEvacuate", ...(sessions ? { sessions: [...sessions] } : {}) }).catch(
        fail,
      ),
    bringBack: (sessions) =>
      void callNative("action.run", {
        id: "cloudBringBackAll",
        ...(sessions ? { sessions: [...sessions] } : {}),
      }).catch(fail),
    cancelEvacuate: () => void callNative("action.run", { id: "cloudEvacuate.cancel" }).catch(fail),
    // A row names its chat in `sessions`: `session` is the tab's own chat, which the app refuses once the tab shows another.
    setMode: (session, mode) =>
      void callNative("action.run", { id: "chatPlace.set", mode, sessions: [session] }).catch(fail),
  };
}

/// The chat's place from `pane.tabState`, and its actions.
export function usePlace(session: string | undefined, say?: (text: string) => void) {
  const { place, evacuate } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say) : undefined), [session, say]);
  return { place, evacuate, actions };
}
