// Which composer strip the page draws (composerStrip.experiment.ts): the app's Debug Settings
// choice when it set one (AgentPaneTheme.swift `composerStrip`, which applyAgentTheme puts on the
// root as `data-composer-strip`), else the experiment's arm (the gallery's compare view, the
// `cmux.experiments` debug key), else `off`.
import { useSyncExternalStore } from "react";
import { experimentArm, isArm } from "../../../experiments/experiment";
import { composerStrip, type ComposerStripVariant } from "./composerStrip.experiment";

export function composerStripVariant(): ComposerStripVariant {
  const chosen = typeof document === "undefined" ? undefined : document.documentElement.dataset.composerStrip;
  return isArm(composerStrip, chosen) ? chosen : experimentArm(composerStrip);
}

function subscribe(listener: () => void): () => void {
  if (typeof MutationObserver === "undefined" || typeof document === "undefined") return () => undefined;
  const observer = new MutationObserver(listener);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-composer-strip"] });
  return () => observer.disconnect();
}

/// The variant, following the root's attribute live (the app's tunable re-pushes the theme).
export function useComposerStripVariant(): ComposerStripVariant {
  return useSyncExternalStore(subscribe, composerStripVariant, () => "off");
}
