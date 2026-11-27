// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { RenderVariantsPick } from "../../agent-session/acpmux/conversation/RenderVariantsPick";
import { VariantPick } from "./VariantPick";
import { noopFeedSink } from "./sinks";

export interface VariantPickDemoProps {
  surface: "gallery" | "thread" | "many";
}
/** Fixture picks are local: play steps and screenshot jobs never write tracker comments. */
export function VariantPickDemo({ surface }: VariantPickDemoProps) {
  const [currentPick, setCurrentPick] = useState<string | null>(null);
  const ids = surface === "many" ? ["A", "B", "C", "D", "E"] : ["A", "B", "C"];
  const preview = (id: string) => <p>{id} · Component preview</p>;
  if (surface === "thread")
    return (
      <RenderVariantsPick
        threadId="sample-thread"
        turnId="sample-turn"
        calls={ids.map((id) => ({ id, title: id, recommended: id === "B" }))}
        beads={noopFeedSink}
        feed={noopFeedSink}
        renderPreview={(call) => preview(call.id)}
      />
    );
  return (
    <VariantPick
      options={ids.map((id) => ({ id, label: id, preview: preview(id) }))}
      recommendedId="B"
      currentPick={currentPick}
      onPick={setCurrentPick}
    />
  );
}
