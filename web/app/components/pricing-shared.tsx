import type { ReactNode } from "react";

export const SHOW_VAULT = false;
export const SHOW_HOSTED_NETWORKING = false;

export type CompareRow = {
  label: string;
  free: string;
  pro: string;
  team: string;
  enterprise: string;
  vault?: boolean;
  hostedNetworking?: boolean;
};

export type SizeRow = {
  size: string;
  use: string;
  rate: string;
};

export type FaqItem = {
  q: string;
  a: string;
  vault?: boolean;
};

export function visibleProFeatures({
  base,
  vault,
  hostedNetworking,
}: {
  base: string[];
  vault: string[];
  hostedNetworking: string[];
}) {
  let features = SHOW_VAULT
    ? [...base.slice(0, 2), ...vault, ...base.slice(2)]
    : base;
  if (SHOW_HOSTED_NETWORKING) {
    features = [
      ...features.slice(0, -1),
      ...hostedNetworking,
      ...features.slice(-1),
    ];
  }
  return features;
}

export function visibleCompareRows(rows: CompareRow[]) {
  return rows.filter(
    (row) =>
      (SHOW_VAULT || !row.vault) &&
      (SHOW_HOSTED_NETWORKING || !row.hostedNetworking),
  );
}

export function visibleFaqItems(items: FaqItem[]) {
  return items.filter((item) => SHOW_VAULT || !item.vault);
}

export function PlanCard({
  name,
  price,
  period,
  badge,
  children,
}: {
  name: string;
  price: string;
  period?: string;
  badge?: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="relative flex h-full flex-col border border-border p-6">
      {badge ? <div className="absolute right-6 top-6">{badge}</div> : null}
      <h2 className="pr-28 text-sm font-medium tracking-tight">{name}</h2>
      <div className="mt-3 flex items-baseline gap-1.5">
        <span className="text-3xl font-medium tracking-tight">{price}</span>
        {period ? <span className="text-sm text-muted">{period}</span> : null}
      </div>
      <div className="mt-6">{children}</div>
    </div>
  );
}

export function FeatureList({
  items,
  muted,
}: {
  items: string[];
  muted?: boolean;
}) {
  return (
    <ul
      className={`mt-4 space-y-2.5 text-[15px] leading-relaxed ${
        muted ? "text-muted" : ""
      }`}
    >
      {items.map((item, i) => (
        <li key={i} className="flex gap-2.5">
          <CheckIcon />
          <span>{item}</span>
        </li>
      ))}
    </ul>
  );
}

export function PrimaryLink({
  href,
  children,
}: {
  href: string;
  children: ReactNode;
}) {
  return (
    <a
      href={href}
      className="inline-flex w-full items-center justify-center whitespace-nowrap bg-foreground px-5 py-2.5 text-[15px] font-medium transition-opacity hover:opacity-85"
      style={{
        color: "var(--button-foreground, var(--background))",
        textDecoration: "none",
      }}
    >
      {children}
    </a>
  );
}

export function SecondaryLink({
  href,
  children,
}: {
  href: string;
  children: ReactNode;
}) {
  return (
    <a
      href={href}
      className="inline-flex w-full items-center justify-center whitespace-nowrap border border-border px-5 py-2.5 text-[15px] font-medium text-foreground transition-colors hover:bg-code-bg"
    >
      {children}
    </a>
  );
}

export function DisabledButton({ children }: { children: ReactNode }) {
  return (
    <button
      className="inline-flex w-full items-center justify-center whitespace-nowrap border border-border px-5 py-2.5 text-[15px] font-medium text-muted"
      disabled
    >
      {children}
    </button>
  );
}

export function CurrentPlanBadge({ children }: { children: ReactNode }) {
  return (
    <span className="whitespace-nowrap border border-border px-2 py-1 text-xs font-medium">
      {children}
    </span>
  );
}

export function PricingCompareTable({
  rows,
  names,
  prices,
  stickyTopClassName = "top-12",
}: {
  rows: CompareRow[];
  names: {
    free: string;
    pro: string;
    team: string;
    enterprise: string;
  };
  prices: {
    free: string;
    pro: string;
    team: string;
    enterprise: string;
  };
  stickyTopClassName?: string;
}) {
  return (
    <table className="w-full border-separate border-spacing-0 text-[15px]">
      <thead>
        <tr>
          <th
            className={`sticky ${stickyTopClassName} z-20 border-b border-border py-3 pr-4 text-left align-bottom font-medium min-w-[12rem] [background:var(--pricing-sticky-bg,var(--background))]`}
          />
          <ColumnHead
            name={names.free}
            price={prices.free}
            stickyTopClassName={stickyTopClassName}
          />
          <ColumnHead
            name={names.pro}
            price={prices.pro}
            stickyTopClassName={stickyTopClassName}
          />
          <ColumnHead
            name={names.team}
            price={prices.team}
            stickyTopClassName={stickyTopClassName}
          />
          <ColumnHead
            name={names.enterprise}
            price={prices.enterprise}
            stickyTopClassName={stickyTopClassName}
          />
        </tr>
      </thead>
      <tbody>
        {rows.map((row, i) => (
          <tr key={i}>
            <th
              scope="row"
              className="border-b border-border py-3 pr-4 text-left align-top font-normal"
            >
              {row.label}
            </th>
            <CompareCell value={row.free} />
            <CompareCell value={row.pro} />
            <CompareCell value={row.team} />
            <CompareCell value={row.enterprise} />
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export function PricingSizeTable({
  rows,
  title,
  body,
  colSize,
  colUse,
  colRate,
}: {
  rows: SizeRow[];
  title: string;
  body: string;
  colSize: string;
  colUse: string;
  colRate: string;
}) {
  return (
    <section className="mt-16 border-t border-border pt-10">
      <h2 className="mb-3 text-xs font-medium tracking-tight text-muted">
        {title}
      </h2>
      <p className="max-w-2xl text-[15px] text-muted">{body}</p>
      <div className="mt-4 overflow-x-auto">
        <table className="w-full border-collapse text-[15px]">
          <thead>
            <tr className="border-b border-border">
              <th className="py-3 pr-4 text-left align-bottom font-medium min-w-[10rem]">
                {colSize}
              </th>
              <th className="px-4 py-3 text-left align-bottom font-medium">
                {colUse}
              </th>
              <th className="whitespace-nowrap px-4 py-3 text-left align-bottom font-medium">
                {colRate}
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row, i) => (
              <tr key={i} className="border-b border-border">
                <th
                  scope="row"
                  className="whitespace-nowrap py-3 pr-4 text-left align-top font-normal"
                >
                  {row.size}
                </th>
                <td className="px-4 py-3 text-left align-top text-muted">
                  {row.use}
                </td>
                <td className="whitespace-nowrap px-4 py-3 text-left align-top">
                  {row.rate}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function ColumnHead({
  name,
  price,
  stickyTopClassName,
}: {
  name: string;
  price: string;
  stickyTopClassName: string;
}) {
  return (
    <th
      className={`sticky ${stickyTopClassName} z-20 border-b border-border px-4 py-3 text-left align-bottom font-medium [background:var(--pricing-sticky-bg,var(--background))]`}
    >
      {name}
      <span className="block text-xs font-normal text-muted">{price}</span>
    </th>
  );
}

function CompareCell({ value }: { value: string }) {
  const base = "border-b border-border px-4 py-3 text-left align-top";
  if (value === "true") {
    return (
      <td className={base}>
        <span className="inline-flex text-foreground">
          <CheckIcon inline />
        </span>
      </td>
    );
  }
  if (value === "false") {
    return (
      <td className={`${base} text-muted`} aria-label="Not included">
        <span aria-hidden="true">-</span>
      </td>
    );
  }
  return <td className={`${base} text-[13px] text-muted`}>{value}</td>;
}

function CheckIcon({ inline }: { inline?: boolean }) {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={inline ? "shrink-0" : "mt-1 shrink-0 text-muted"}
      aria-hidden="true"
    >
      <path d="M20 6L9 17l-5-5" />
    </svg>
  );
}
