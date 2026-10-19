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

export type PriceTable = Readonly<Record<string, Readonly<Record<string, ReadonlyArray<ProviderPrices>>>>>;

export const PROVIDER_PRICES: PriceTable = {
  freestyle: {
    "*": [
      {
        effective_from: "2026-10-17T00:00:00.000Z",
        vcpuHourMicrodollars: 40_320,
        memoryGibHourMicrodollars: 12_900,
        storageGibHourMicrodollars: 86,
        transferGbMicrodollars: 20_000,
      },
    ],
  },
};

export const pricesFor = (provider: string, region: string, _at: Date, table: PriceTable = PROVIDER_PRICES): ProviderPrices | null => {
  const prices = table[provider]?.[region] ?? table[provider]?.["*"];
  if (prices === undefined || prices.length === 0) return null;
  const ordered = [...prices].sort((left, right) => Date.parse(left.effective_from) - Date.parse(right.effective_from));
  const matching = ordered.filter((price) => Date.parse(price.effective_from) <= _at.getTime()).at(-1);
  return matching ?? ordered[0] ?? null;
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
