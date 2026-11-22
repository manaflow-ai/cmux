import { useContext } from "react";
import { experimentArm, isArm } from "../../experiments/experiment";
import { useExperimentSwitch } from "../../experiments/switches";
import { composerV2Look, type ComposerV2Look } from "./composerV2.experiment";
import { type ComposerLook, useComposerLook } from "./composerLook";
import { OnNewTab } from "./newTabComposer";

/// The composer refresh's look, read once per page: arms are installed before the page loads
/// (`globalThis.cmuxExperiments`, the gallery's `arm` query key) or kept in `cmux.experiments`
/// (read on reload), so neither changes while the page runs. `armed` is true when the host
/// override names a composer-v2-look arm: a gallery stage shows the look with the setting off.
let resolved: { arm: ComposerV2Look; armed: boolean } | undefined;

function resolveLook(): { arm: ComposerV2Look; armed: boolean } {
  resolved ??= {
    arm: experimentArm(composerV2Look),
    armed: isArm(composerV2Look, globalThis.cmuxExperiments?.[composerV2Look.id]),
  };
  return resolved;
}

/// The composer refresh's arm while it is on (Settings > Advanced > Experiments > Composer Refresh, `experiments.composerV2`, or a
/// gallery stage that arms composer-v2-look), else undefined. ComposerBox.tsx writes it as
/// `data-composer-v2` on `.acpmux-composer-box`; composerV2.css draws each look.
export function useComposerV2(): ComposerV2Look | undefined {
  const on = useExperimentSwitch("composerV2");
  const look = resolveLook();
  return on || look.armed ? look.arm : undefined;
}

/// The composer's look with the refresh on: Codex's in-box row, which holds the chip row and the
/// footer composerV2.css lays out (model left, + and Send right). New Tab keeps its own look.
export function useComposerLookWithV2(): ComposerLook {
  const look = useComposerLook();
  const onNewTab = useContext(OnNewTab);
  return useComposerV2() !== undefined && !onNewTab ? "codex" : look;
}
