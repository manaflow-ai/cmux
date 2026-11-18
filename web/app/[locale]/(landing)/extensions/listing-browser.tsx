"use client";

import { useMemo, useState } from "react";
import { Link } from "@/i18n/navigation";

export type BrowserTier = "all" | "plugin" | "theme" | "snippet" | "setup";

/** What a card shows: plain data, so the server renders every card and the browser only filters. */
export type BrowserCard = {
  key: string;
  href: string;
  tier: Exclude<BrowserTier, "all">;
  name: string;
  summary: string;
  publisher: string;
  iconUrl?: string;
  downloads: number;
  downloadsLabel?: string;
  updatedAt?: string;
  updatedLabel?: string;
  version?: string;
  search: string;
};

type Sort = "popular" | "updated" | "name";

export type BrowserLabels = {
  search: string;
  tiers: Record<BrowserTier, string>;
  sort: string;
  sorts: Record<Sort, string>;
  noMatches: string;
};

export function ListingBrowser({
  cards,
  labels,
  tiers,
  initialTier = "all",
}: {
  cards: BrowserCard[];
  labels: BrowserLabels;
  tiers: Array<{ tier: BrowserTier; count: number }>;
  initialTier?: BrowserTier;
}) {
  const [tier, setTier] = useState<BrowserTier>(initialTier);
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<Sort>("popular");

  const shown = useMemo(() => {
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    const matching = cards.filter(
      (card) => (tier === "all" || card.tier === tier) && words.every((word) => card.search.includes(word)),
    );
    return matching.sort((a, b) => compareCards(a, b, sort));
  }, [cards, query, sort, tier]);

  return (
    <div>
      <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div role="tablist" aria-label={labels.tiers.all} className="flex flex-wrap gap-1.5">
          {tiers.map(({ tier: value, count }) => (
            <button
              key={value}
              type="button"
              role="tab"
              aria-selected={tier === value}
              onClick={() => setTier(value)}
              className={`rounded-full border px-3 py-1 text-[13px] transition-colors ${
                tier === value ? "border-foreground bg-foreground text-background" : "border-border hover:bg-code-bg"
              }`}
            >
              {labels.tiers[value]} <span className={tier === value ? "opacity-70" : "text-muted"}>{count}</span>
            </button>
          ))}
        </div>
        <div className="flex gap-2">
          <input
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={labels.search}
            aria-label={labels.search}
            className="w-full min-w-0 rounded-full border border-border bg-background px-4 py-1.5 text-[14px] outline-none focus:border-foreground/40 sm:w-64"
          />
          <select
            value={sort}
            onChange={(event) => setSort(event.target.value as Sort)}
            aria-label={labels.sort}
            className="rounded-full border border-border bg-background px-3 py-1.5 text-[13px]"
          >
            {(Object.keys(labels.sorts) as Sort[]).map((value) => (
              <option key={value} value={value}>
                {labels.sorts[value]}
              </option>
            ))}
          </select>
        </div>
      </div>
      {shown.length === 0 ? (
        <p className="rounded-xl border border-dashed border-border px-6 py-10 text-center text-[14px] text-muted">{labels.noMatches}</p>
      ) : (
        <ul className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {shown.map((card) => (
            <BrowserCardItem key={card.key} card={card} tierLabel={tier === "all" ? labels.tiers[card.tier] : null} />
          ))}
        </ul>
      )}
    </div>
  );
}

function compareCards(a: BrowserCard, b: BrowserCard, sort: Sort): number {
  if (sort === "updated") return (b.updatedAt ?? "").localeCompare(a.updatedAt ?? "") || a.name.localeCompare(b.name);
  if (sort === "name") return a.name.localeCompare(b.name);
  return b.downloads - a.downloads || a.name.localeCompare(b.name);
}

function BrowserCardItem({ card, tierLabel }: { card: BrowserCard; tierLabel: string | null }) {
  const meta = [card.version ? `v${card.version}` : null, card.downloadsLabel, card.updatedLabel].filter(Boolean).join(" · ");
  return (
    <li className="min-w-0">
      <Link href={card.href} className="group flex h-full gap-3 rounded-xl border border-border p-4 transition-colors hover:bg-code-bg">
        {card.iconUrl ? (
          // eslint-disable-next-line @next/next/no-img-element -- remote icon at the reviewed commit
          <img
            src={card.iconUrl}
            alt=""
            width={44}
            height={44}
            loading="lazy"
            decoding="async"
            referrerPolicy="no-referrer"
            className="h-11 w-11 shrink-0 rounded-[10px] border border-border bg-code-bg object-cover"
          />
        ) : (
          <div aria-hidden className="flex h-11 w-11 shrink-0 items-center justify-center rounded-[10px] border border-border bg-code-bg text-[18px] font-semibold text-muted">
            {card.name.slice(0, 1).toUpperCase()}
          </div>
        )}
        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-2">
            <h3 className="truncate text-[15px] font-semibold leading-tight">{card.name}</h3>
            {tierLabel ? <span className="shrink-0 rounded-full border border-border px-1.5 text-[11px] leading-[18px] text-muted">{tierLabel}</span> : null}
          </div>
          <p className="mt-0.5 truncate text-[13px] text-muted">{card.publisher}</p>
          <p className="mt-2 line-clamp-2 text-[14px] leading-snug">{card.summary}</p>
          {meta ? <p className="mt-2 text-[12px] text-muted">{meta}</p> : null}
        </div>
      </Link>
    </li>
  );
}
