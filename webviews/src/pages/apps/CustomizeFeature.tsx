// The Customize cmux… card at the top of Discover (Leo, 2026-11-22, ask-931361017e: "putting a card
// in the app store saying "Customize cmux..." or something idk not too much but enough to just
// expand out into the various verified or other customizations"). Closed, it names the first verified
// looks; one click on Show All opens it in place to every verified look and every switch group, each a
// chip that opens Settings > Customize, with a link to it at the foot. The chips cannot be switches
// here: the App Store page's descriptor (PageDescriptor.apps) has only `cmux.apps.` ops, and
// `cmux.settings.snapshot`, `cmux.settings.set` and `cmux.settings.customize.library` are served
// only to the Settings page (SettingsPageProvider), so the switches themselves live there.
import { useId, useState } from "react";
import type { Strings } from "../shared/i18n";
import { shippedLooks } from "../settings/customizeLooks";
import type { VerifiedLook } from "../settings/customizeChecklist";
import type { AppsStore } from "./store";

/** How many verified looks the card names before "and N more". */
export const NAMED_LOOKS = 4;

/** The switch groups the open card names; each opens Settings > Customize, where they are switches. */
const SWITCH_GROUPS = [
  "store.customize.experiments",
  "store.customize.labs",
  "store.customize.library",
  "store.customize.all",
] as const;

export function CustomizeFeature({
  store,
  strings,
  looks = shippedLooks(),
  open: openAtFirst = false,
}: {
  store: Pick<AppsStore, "openCustomize">;
  strings: Strings;
  looks?: readonly VerifiedLook[];
  /** Drawn open (the gallery's open variant). */
  open?: boolean;
}) {
  const { t, format } = strings;
  const panelId = useId();
  const [open, setOpen] = useState(openAtFirst);
  const named = looks.slice(0, NAMED_LOOKS);
  const more = looks.length - named.length;
  const settings = () => void store.openCustomize();
  const chip = (key: string, label: string, title?: string) => (
    <button type="button" key={key} className="apps-customize-look" title={title} onClick={settings}>
      {label}
    </button>
  );
  return (
    <section
      className="apps-customize-feature"
      data-open={open ? "" : undefined}
      aria-labelledby="apps-customize-feature-title"
    >
      <div className="apps-customize-feature-head">
        <span className="apps-customize-feature-text">
          <strong id="apps-customize-feature-title" className="apps-customize-feature-title">
            {t("store.customize.title")}
          </strong>
          <span className="apps-customize-feature-body">{t("store.customize.body")}</span>
          {!open && named.length > 0 && (
            <span className="apps-customize-looks" aria-label={t("store.customize.looks")}>
              {named.map((look) => chip(look.id, look.name, look.tagline))}
              {more > 0 && <span className="apps-customize-more">{format("store.customize.more", String(more))}</span>}
            </span>
          )}
        </span>
        <button
          type="button"
          className="apps-button primary"
          aria-expanded={open}
          aria-controls={panelId}
          onClick={() => setOpen(!open)}
        >
          {t(open ? "store.customize.hide" : "store.customize.show")}
        </button>
      </div>
      {open && (
        <div className="apps-customize-panel" id={panelId}>
          {looks.length > 0 && (
            <div className="apps-customize-section">
              <span className="apps-customize-heading">{t("store.customize.looks")}</span>
              <span className="apps-customize-looks" aria-label={t("store.customize.looks")}>
                {looks.map((look) => chip(look.id, look.name, look.tagline))}
              </span>
            </div>
          )}
          <div className="apps-customize-section">
            <span className="apps-customize-heading">{t("store.customize.switches")}</span>
            <span className="apps-customize-looks" aria-label={t("store.customize.switches")}>
              {SWITCH_GROUPS.map((key) => chip(key, t(key)))}
            </span>
          </div>
          <button type="button" className="apps-customize-link" onClick={settings}>
            {t("store.customize.settingsLink")}
          </button>
        </div>
      )}
    </section>
  );
}
