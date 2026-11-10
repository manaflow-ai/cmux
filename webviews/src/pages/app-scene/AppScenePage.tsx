import { SceneMount } from "../../apps/scene/panels";
import type { MountedScene } from "../../apps/scene/panelsClient";

/** An app's pane: its one mounted scene across the page, scrolling when it is taller than the pane.
 * A route that names no app shows nothing. */
export function AppScenePage({ mounted }: { mounted: MountedScene | undefined }) {
  return <div className="app-scene-page">{mounted ? <SceneMount mounted={mounted} /> : null}</div>;
}
