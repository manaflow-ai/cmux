// Settings > Look and Feel > Design System (RFD 0009 slice 8): the design system extension views
// are drawn with, as this person has it. The Rust side resolves it, layer over layer (cmux, the
// active theme file's `design` key, design.json beside the settings file), marks each value cmux
// changed since the person's recorded base, and draws it with the SDK's own DesignSystemView in the
// CLI's app host (`cmux --json ext design --show --scene`, cmux-tui cli/ext/design_layers.rs). This
// card only applies that scene's ops to a SceneStore: it never draws the viewer itself, so the page
// and an extension's own viewer can never differ. A layer that did not read is listed under it.
import { useLayoutEffect, useMemo, useRef } from "react";
import { useQuery } from "@tanstack/react-query";
import { SceneRenderer } from "../../../apps/scene/SceneRenderer";
import { SceneStore } from "../../../apps/scene/store";
import { useStore } from "../context";
import type { DesignSystemState } from "../ops";
import { designSystemQuery } from "../sectionQueries";
import { t } from "../strings";

export function DesignSystemCard({ reveal = false }: { reveal?: boolean }) {
  const store = useStore();
  const query = useQuery(designSystemQuery(store));
  if (!query.isFetched) return null;
  return <DesignSystemCardView state={query.data ?? null} reveal={reveal} />;
}

/** The card as it draws, from the CLI's answer (null: it could not be read). */
export function DesignSystemCardView({ state, reveal = false }: { state: DesignSystemState | null; reveal?: boolean }) {
  const card = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    if (reveal) card.current?.scrollIntoView?.({ block: "start" });
  }, [reveal]);
  const scene = useMemo(() => {
    if (!state) return null;
    const next = new SceneStore();
    next.apply(state.scene, true);
    return next;
  }, [state]);
  const problems = state?.design ?? [];
  return (
    <section className="group design-system-card" data-card="designSystem" ref={card}>
      {scene ? (
        // The viewer is read only: its scene has no actions, so a dispatch has nothing to send.
        <SceneRenderer store={scene} dispatch={() => {}} />
      ) : (
        <p className="design-system-card__unavailable">{t("settingsPage.designSystem.unavailable")}</p>
      )}
      {problems.length > 0 ? (
        <div className="design-system-card__problems" data-design-problems>
          <h3 className="group-title">{t("settingsPage.designSystem.problems")}</h3>
          <ul>
            {problems.map((problem) => (
              <li key={problem.message}>{problem.message}</li>
            ))}
          </ul>
        </div>
      ) : null}
    </section>
  );
}
