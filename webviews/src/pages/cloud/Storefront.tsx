// The Cloud storefront (`#/get`, and the page itself while signed out or with no machines): what a
// cloud machine gives, the plan's sizes as product cards and Get. Every number comes from the plan
// the backend answers (`CloudPlan`): sizes, which ones the plan locks and the active machine limit.
// The page prices nothing and computes no limit; "See plans" links the public plans page. Get opens
// the create sheet on that size, the host confirms the create natively (a money op), and the new
// machine opens in a workspace once it runs (store `openWhenRunning`).
import type { Strings } from "../shared/i18n";
import { AccountPanel } from "./AccountPanel";
import { formatMegabytes, memoryChoices } from "./model";
import { AccountOps, PLANS_URL, type CloudPlan } from "./ops";
import type { CloudState, CloudStore } from "./store";
import { format, L, type StringKey } from "./strings";

/** What a size suits, by memory: a suggestion, not a limit. */
export function tierHint(mb: number): StringKey {
  if (mb <= 4096) return L.storeTierSmall;
  if (mb <= 8192) return L.storeTierMedium;
  if (mb <= 16_384) return L.storeTierLarge;
  return L.storeTierHuge;
}

const BENEFITS: readonly { title: StringKey; body: StringKey }[] = [
  { title: L.storeBenefitAwayTitle, body: L.storeBenefitAwayBody },
  { title: L.storeBenefitHeatTitle, body: L.storeBenefitHeatBody },
  { title: L.storeBenefitForkTitle, body: L.storeBenefitForkBody },
];

export function Storefront({ store, state, strings }: { store: CloudStore; state: CloudState; strings: Strings }) {
  const { t } = strings;
  const signedIn = !!state.auth?.signedIn;
  const plan = state.plan;
  const choices = memoryChoices(plan);
  const full = !!plan && plan.limits.max_active > 0 && plan.usage.active >= plan.limits.max_active;
  const firstAllowed = choices.find((choice) => choice.allowed)?.mb;
  const cta = () => {
    if (!signedIn)
      return state.unavailable.includes(AccountOps.signIn) ? (
        <p className="cloud-muted cloud-unavailable">{t(L.unavailable)}</p>
      ) : (
        <button type="button" className="cloud-button primary cloud-signin-button" onClick={() => void store.signIn()}>
          {t(L.signIn)}
        </button>
      );
    // The plan is still loading, or its read failed: no offer until the backend answers one.
    if (!plan) return null;
    if (firstAllowed !== undefined && !full)
      return (
        <button
          type="button"
          className="cloud-button primary cloud-store-get-hero"
          onClick={() => store.openCreate(firstAllowed, true)}
        >
          {t(L.storeGetMachine)}
        </button>
      );
    return (
      <a className="cloud-button primary cloud-see-plans" href={PLANS_URL}>
        {t(L.seePlans)}
      </a>
    );
  };
  return (
    <div className="cloud-store">
      <section className="cloud-store-hero" aria-labelledby="cloud-store-headline">
        <div className="cloud-store-hero-text">
          <p className="cloud-store-eyebrow">{t(L.storeEyebrow)}</p>
          <h2 id="cloud-store-headline" className="cloud-store-headline">
            {t(L.storeHeadline)}
          </h2>
          <p className="cloud-store-lede">{t(L.storeLede)}</p>
          <div className="cloud-store-cta">{cta()}</div>
        </div>
        <OffloadArt />
      </section>
      <ul className="cloud-store-benefits">
        {BENEFITS.map((benefit) => (
          <li key={benefit.title} className="cloud-store-benefit">
            <strong className="cloud-store-benefit-title">{t(benefit.title)}</strong>
            <span className="cloud-store-benefit-body">{t(benefit.body)}</span>
          </li>
        ))}
      </ul>
      {signedIn && (
        <section className="cloud-store-sizes" aria-labelledby="cloud-store-sizes-title">
          <header className="cloud-store-sizes-header">
            <h3 id="cloud-store-sizes-title" className="cloud-section-title">
              {t(L.storeSizes)}
            </h3>
            {plan && <Availability plan={plan} full={full} strings={strings} />}
          </header>
          {!plan && state.planFailed ? (
            <p className="cloud-muted cloud-store-no-plan" role="alert">
              {t(L.storePlanFailed)}{" "}
              <button type="button" className="cloud-link-button" onClick={() => void store.retryPlan()}>
                {t(L.retry)}
              </button>
            </p>
          ) : !plan ? (
            <p className="cloud-muted cloud-store-no-plan">{t(L.loading)}</p>
          ) : choices.length === 0 ? (
            <p className="cloud-muted cloud-store-no-plan">{t(L.storeNoPlan)}</p>
          ) : (
            <ul className="cloud-store-tiers">
              {choices.map(({ mb, allowed }) => (
                <li key={mb} className={`cloud-store-tier${allowed ? "" : " locked"}`}>
                  <span className="cloud-store-tier-size">{formatMegabytes(mb, t, strings.language)}</span>
                  <span className="cloud-store-tier-unit">{t(L.storeMemory)}</span>
                  <span className="cloud-store-tier-hint">{t(tierHint(mb))}</span>
                  <span className="cloud-store-tier-footer">
                    <span className="cloud-badge">{t(allowed ? L.storeIncluded : L.sizeNotInPlan)}</span>
                    {allowed ? (
                      <button
                        type="button"
                        className="cloud-button primary cloud-store-get"
                        disabled={full}
                        aria-label={format(t(L.storeGetSize), { size: formatMegabytes(mb, t, strings.language) })}
                        onClick={() => store.openCreate(mb, true)}
                      >
                        {t(L.storeGet)}
                      </button>
                    ) : (
                      <a
                        className="cloud-button cloud-see-plans"
                        href={PLANS_URL}
                        aria-label={`${formatMegabytes(mb, t, strings.language)}: ${t(L.seePlans)}`}
                      >
                        {t(L.seePlans)}
                      </a>
                    )}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </section>
      )}
      <p className="cloud-muted cloud-store-note">{t(L.storeNote)}</p>
      {/* Sign-out, team switch and usage stay reachable from the storefront (an empty team has no list). */}
      {signedIn && (
        <div className="cloud-store-account">
          <AccountPanel store={store} state={state} strings={strings} />
        </div>
      )}
    </div>
  );
}

/** Live availability from the plan: machines active of the plan's limit, and when the limit is reached. */
function Availability({ plan, full, strings }: { plan: CloudPlan; full: boolean; strings: Strings }) {
  const { t } = strings;
  if (plan.limits.max_active <= 0) return null;
  return (
    <span className={`cloud-store-availability${full ? " full" : ""}`}>
      <span className="cloud-dot" aria-hidden="true" />
      {format(t(full ? L.storeAvailabilityFull : L.storeAvailability), {
        used: plan.usage.active,
        limit: plan.limits.max_active,
      })}
    </span>
  );
}

/**
 * Work moving from a laptop to a cloud machine: three packets travel the link. The packets are HTML
 * layers over the drawing that animate only `transform` and `opacity` (styles.css), so the compositor
 * moves them and the page renders nothing per frame. They move only when the system allows motion
 * (`prefers-reduced-motion`, which the host's motion switches drive).
 */
function OffloadArt() {
  return (
    <div className="cloud-store-art" aria-hidden="true">
      <svg viewBox="0 0 240 120" focusable="false">
        <g className="cloud-store-art-laptop">
          <rect x="14" y="34" width="62" height="42" rx="5" />
          <path d="M6 82 h78 l-6 8 h-66 z" />
          <rect className="cloud-store-art-line" x="22" y="44" width="30" height="4" rx="2" />
          <rect className="cloud-store-art-line" x="22" y="53" width="44" height="4" rx="2" />
          <rect className="cloud-store-art-line" x="22" y="62" width="22" height="4" rx="2" />
        </g>
        <path className="cloud-store-art-link" d="M92 60 C 120 30, 140 30, 164 52" />
        <g className="cloud-store-art-cloud">
          <path d="M176 86 h44 a16 16 0 0 0 -2 -32 a22 22 0 0 0 -42 -4 a18 18 0 0 0 0 36 z" />
          <rect className="cloud-store-art-line" x="182" y="62" width="30" height="4" rx="2" />
          <rect className="cloud-store-art-line" x="182" y="71" width="20" height="4" rx="2" />
          <circle className="cloud-store-art-led" cx="214" cy="73" r="3" />
        </g>
      </svg>
      <span className="cloud-store-art-packet p1" />
      <span className="cloud-store-art-packet p2" />
      <span className="cloud-store-art-packet p3" />
    </div>
  );
}
