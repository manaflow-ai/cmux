/**
 * Provider list prices, in micro-dollars per provider unit-hour. Freestyle's
 * published prices were checked on 2026-10-17:
 * https://www.freestyle.sh/docs/vms/pricing-and-limits
 */
export interface ProviderPrices {
  readonly effective_from: string;
  readonly vcpuHourMicrodollars: number;
  readonly memoryGibHourMicrodollars: number;
  readonly storageGibHourMicrodollars: number;
  readonly transferGbMicrodollars: number;
}

export const PROVIDER_PRICES: Readonly<Record<string, Readonly<Record<string, ProviderPrices>>>> = {
  freestyle: {
    "*": {
      effective_from: "2026-10-17T00:00:00.000Z",
      vcpuHourMicrodollars: 40_320,
      memoryGibHourMicrodollars: 12_900,
      storageGibHourMicrodollars: 86,
      transferGbMicrodollars: 20_000,
    },
  },
};

export const pricesFor = (provider: string, region: string, _at: Date): ProviderPrices | null => {
  const prices = PROVIDER_PRICES[provider]?.[region] ?? PROVIDER_PRICES[provider]?.["*"];
  if (prices === undefined) return null;
  // A later table entry must never make earlier historical hours unpriceable;
  // the earliest published price remains the fallback before its effective date.
  return prices;
};

/** Invalid markup disables export; it never makes request handling fail. */
export const parseMarkupBps = (value: string | undefined): number | null => {
  if (value === undefined || value.trim() === "") return 0;
  const text = value.trim();
  if (!/^\d+$/u.test(text)) return null;
  const parsed = Number(text);
  return Number.isSafeInteger(parsed) ? parsed : null;
};

export const markedUpMicrodollars = (listMicrodollars: number, markupBps: number): number =>
  Math.round((listMicrodollars * (10_000 + markupBps)) / 10_000);

export const intervalCostMicrodollars = (
  interval: { readonly vcpus: number; readonly memoryMb: number; readonly storageMb: number; readonly computeBilled: boolean },
  hours: number,
  prices: ProviderPrices,
): number => {
  const compute = interval.computeBilled ? interval.vcpus * prices.vcpuHourMicrodollars : 0;
  const memory = interval.computeBilled ? (interval.memoryMb / 1024) * prices.memoryGibHourMicrodollars : 0;
  const storage = (interval.storageMb / 1024) * prices.storageGibHourMicrodollars;
  return Math.round((compute + memory + storage) * hours);
};
