// The App Store's Features tab (Leo, 2026-10-21: "have that app store area as a sort of way to, like,
// toggle things on and off ... instead of having it be so-called experimental"). Every built-in
// feature cmux ships (backgrounds, the Chief pet, Now Playing, every Lab and Experiment) as a switch.
// A switch is its existing setting, read and written by the daemon (cmux-tui server/app_features.rs):
// this view only draws the list it returns, so Settings, the CLI and this tab always agree.
import { useEffect, useMemo } from "react";
import type { Strings } from "../shared/i18n";
import { Switch } from "../../ui/Switch";
import "../../ui/controls.css";
import type { FeaturesStyle } from "./model";
import type { AppsSnapshot, AppsStore } from "./store";
import type { FeatureRow } from "./types";

/** Rows by heading, in the order the daemon lists them (curated groups first, then Labs, Experiments). */
export function featureGroups(rows: readonly FeatureRow[], query = ""): [string, FeatureRow[]][] {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const groups = new Map<string, FeatureRow[]>();
  for (const row of rows) {
    const text = `${row.title.text} ${row.summary?.text ?? ""} ${row.group} ${row.key}`.toLowerCase();
    if (!words.every((word) => text.includes(word))) continue;
    const list = groups.get(row.group) ?? [];
    list.push(row);
    groups.set(row.group, list);
  }
  return [...groups];
}

export function FeaturesView({
  snap,
  store,
  strings,
}: {
  snap: Pick<AppsSnapshot, "features" | "featuresStatus" | "featuresUnsupported" | "featuresStyle" | "query">;
  store: Pick<AppsStore, "loadFeatures" | "setFeature">;
  strings: Strings;
}) {
  const { t } = strings;
  // Settings or the CLI can change a feature while the tab is open: read on open and on return.
  useEffect(() => {
    void store.loadFeatures();
    const reread = () => {
      if (document.visibilityState === "visible") void store.loadFeatures();
    };
    window.addEventListener("focus", reread);
    document.addEventListener("visibilitychange", reread);
    return () => {
      window.removeEventListener("focus", reread);
      document.removeEventListener("visibilitychange", reread);
    };
  }, [store]);
  const groups = useMemo(() => featureGroups(snap.features, snap.query), [snap.features, snap.query]);
  if (snap.featuresStatus === "error" && snap.features.length === 0) {
    return (
      <div className="apps-scroll">
        <output className="apps-state apps-state-error">
          <strong>{t(snap.featuresUnsupported ? "store.features.unsupported" : "store.features.error")}</strong>
        </output>
      </div>
    );
  }
  if (snap.features.length === 0) return <div className="apps-scroll" aria-busy={snap.featuresStatus === "loading"} />;
  const style: FeaturesStyle = snap.featuresStyle;
  return (
    <div className="apps-scroll">
      <div className="apps-features" data-features-style={style}>
        <p className="apps-features-intro">{t("store.features.intro")}</p>
        {groups.length === 0 && (
          <output className="apps-state apps-state-empty">
            <strong>{t("store.empty.noMatches")}</strong>
          </output>
        )}
        {groups.map(([group, rows]) => (
          <section key={group} className="apps-features-group" aria-label={group}>
            <div className="apps-section-heading">
              <h3>{group}</h3>
            </div>
            <ul className="apps-features-list">
              {rows.map((row) => (
                <FeatureItem key={row.id} row={row} style={style} store={store} strings={strings} />
              ))}
            </ul>
          </section>
        ))}
      </div>
    </div>
  );
}

function FeatureItem({
  row,
  style,
  store,
  strings,
}: {
  row: FeatureRow;
  style: FeaturesStyle;
  store: Pick<AppsStore, "setFeature">;
  strings: Strings;
}) {
  const { t } = strings;
  const toggle = (on: boolean) => void store.setFeature(row.id, on);
  if (style === "chips") {
    return (
      <li className="apps-feature" data-feature={row.id}>
        <button
          type="button"
          role="switch"
          aria-checked={row.on}
          disabled={row.managed}
          className="apps-feature-chip"
          data-on={row.on ? "" : undefined}
          onClick={() => toggle(!row.on)}
        >
          {row.title.text}
        </button>
      </li>
    );
  }
  return (
    <li className="apps-feature" data-feature={row.id} data-on={row.on ? "" : undefined}>
      <span className="apps-feature-text">
        <strong className="apps-feature-title">{row.title.text}</strong>
        {row.summary?.text && <span className="apps-feature-summary">{row.summary.text}</span>}
        {row.managed && <span className="apps-feature-managed">{t("store.features.managed")}</span>}
      </span>
      <Switch
        size={style === "tiles" ? "md" : "sm"}
        aria-label={row.title.text}
        checked={row.on}
        disabled={row.managed}
        onCheckedChange={toggle}
      />
    </li>
  );
}
