// A page's feature tips: the scheduler (controller.ts) and the one callout it shows (ui/FeatureTip).
import { useCallback, useEffect, useRef, useState } from "react";
import { FeatureTip, type FeatureTipLook } from "../FeatureTip";
import {
  createTipController,
  type ShownTip,
  type TipAnchor,
  type TipController,
  type TipControllerOptions,
} from "./controller";
import type { FeatureTipEntry } from "./policy";
import type { LaunchStore, TipHost } from "./store";

export interface FeatureTipHostProps {
  tips: readonly FeatureTipEntry[];
  anchors: Readonly<Record<string, TipAnchor>>;
  /** The Settings toggle (updates.showFeatureTips). */
  enabled: boolean;
  /** An agent's turn is running. */
  streaming: boolean;
  typing(): boolean;
  host: TipHost;
  launch: LaunchStore;
  labels: { new: string; close: string };
  look?: FeatureTipLook;
  /** The gallery's still: a page opened long ago, in a focused window. */
  schedule?: Pick<TipControllerOptions, "openedAt" | "focused">;
}

export function FeatureTipHost({
  tips,
  anchors,
  enabled,
  streaming,
  typing,
  host,
  launch,
  labels,
  look,
  schedule,
}: FeatureTipHostProps) {
  const [shown, setShown] = useState<ShownTip | null>(null);
  const controller = useRef<TipController | null>(null);
  const typingRef = useRef(typing);
  typingRef.current = typing;
  // Fixed for a page (the gallery's still).
  const scheduleRef = useRef(schedule);
  const state = useRef({ enabled, streaming });
  state.current = { enabled, streaming };

  useEffect(() => {
    const tipController = createTipController({
      tips,
      anchors,
      host,
      launch,
      doc: document,
      typing: () => typingRef.current(),
      onChange: setShown,
      ...scheduleRef.current,
    });
    controller.current = tipController;
    tipController.update(state.current);
    void tipController.start();
    return () => {
      tipController.stop();
      controller.current = null;
    };
  }, [tips, anchors, host, launch]);

  useEffect(() => controller.current?.update({ enabled, streaming }), [enabled, streaming]);

  const popupRef = useCallback((element: HTMLDivElement | null) => controller.current?.setPopup(element), []);
  const [last, setLast] = useState<ShownTip | null>(null);
  if (shown && shown !== last) setLast(shown);
  // The callout stays placed at its last control while it fades out.
  const tip = shown ?? last;
  if (!tip) return null;
  return (
    <FeatureTip
      anchor={tip.element.isConnected ? tip.element : null}
      open={shown !== null}
      side={tip.side}
      title={tip.tip.title}
      body={tip.tip.body}
      newLabel={labels.new}
      closeLabel={labels.close}
      look={look}
      popupRef={popupRef}
      onClose={() => controller.current?.close()}
    />
  );
}
