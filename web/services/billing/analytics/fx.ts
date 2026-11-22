// Static USD conversion rates for subscription analytics.
//
// ESTIMATE ONLY. The repo has no FX feed, so App Store and Stripe prices in a
// local currency are converted with this hand-maintained table of
// approximate mid-market rates (USD per one unit of the currency, snapshot
// 2026-10). It is good enough to rank storefronts and size MRR; it is not an
// accounting figure. Apple settles in the payout currency at its own monthly
// rate, and App Store prices in many storefronts include VAT or GST, which is
// not removed here. Update the table and FX_RATES_AS_OF together.

export const FX_RATES_AS_OF = "2026-10-01";

/** USD per one unit of the ISO 4217 currency. */
export const USD_PER_UNIT: Readonly<Record<string, number>> = {
  USD: 1,
  EUR: 1.08,
  GBP: 1.27,
  CHF: 1.12,
  JPY: 0.0067,
  CNY: 0.14,
  HKD: 0.128,
  TWD: 0.031,
  KRW: 0.00073,
  SGD: 0.74,
  INR: 0.012,
  IDR: 0.000062,
  THB: 0.028,
  MYR: 0.21,
  PHP: 0.018,
  VND: 0.00004,
  PKR: 0.0036,
  AUD: 0.66,
  NZD: 0.6,
  CAD: 0.73,
  MXN: 0.055,
  BRL: 0.18,
  CLP: 0.00106,
  COP: 0.00024,
  PEN: 0.27,
  SEK: 0.095,
  NOK: 0.094,
  DKK: 0.145,
  PLN: 0.25,
  CZK: 0.043,
  HUF: 0.0027,
  RON: 0.22,
  BGN: 0.55,
  TRY: 0.029,
  ILS: 0.27,
  AED: 0.272,
  SAR: 0.267,
  QAR: 0.275,
  EGP: 0.02,
  ZAR: 0.055,
  NGN: 0.00065,
  KZT: 0.002,
  TZS: 0.00038,
};

/**
 * USD value of `amount` units of `currency`, or null when the currency is
 * not in the table. Callers decide the fallback and must count it.
 */
export function toUsd(amount: number, currency: string | null | undefined): number | null {
  if (!Number.isFinite(amount) || typeof currency !== "string") return null;
  const rate = USD_PER_UNIT[currency.trim().toUpperCase()];
  return rate === undefined ? null : amount * rate;
}
