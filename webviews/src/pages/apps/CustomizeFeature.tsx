// The Customize cmux… card at the top of Discover (Leo, 2026-11-22, ask-931361017e: "putting a card
// in the app store saying "Customize cmux..." or something idk not too much but enough to just
// expand out into the various verified or other customizations"). It names what is one click away
// (experiments, Labs, the person's library, the verified looks by name) and opens Settings >
// Customize, where each is a switch. The App Store page reads no settings (its descriptor has only
// `cmux.apps.` ops), so the switches live there, not here.
import type { Strings } from "../shared/i18n";
import { shippedLooks } from "../settings/customizeLooks";
import type { VerifiedLook } from "../settings/customizeChecklist";
import type { AppsStore } from "./store";

/** How many verified looks the card names before "and N more". */
export const NAMED_LOOKS = 4;

export function CustomizeFeature({
  store,
  strings,
  looks = shippedLooks(),
}: {
  store: Pick<AppsStore, "openCustomize">;
  strings: Strings;
  looks?: readonly VerifiedLook[];
}) {
  const { t, format } = strings;
  const named = looks.slice(0, NAMED_LOOKS);
  const more = looks.length - named.length;
  const open = () => void store.openCustomize();
  return (
    <section className="apps-customize-feature" aria-labelledby="apps-customize-feature-title">
      <span className="apps-customize-feature-text">
        <strong id="apps-customize-feature-title" className="apps-customize-feature-title">
          {t("store.customize.title")}
        </strong>
        <span className="apps-customize-feature-body">{t("store.customize.body")}</span>
        {named.length > 0 && (
          <span className="apps-customize-looks" aria-label={t("store.customize.looks")}>
            {named.map((look) => (
              <button type="button" key={look.id} className="apps-customize-look" title={look.tagline} onClick={open}>
                {look.name}
              </button>
            ))}
            {more > 0 && <span className="apps-customize-more">{format("store.customize.more", String(more))}</span>}
          </span>
        )}
      </span>
      <button type="button" className="apps-button primary" onClick={open}>
        {t("store.customize.open")}
      </button>
    </section>
  );
}
