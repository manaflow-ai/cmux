import type { ReactNode } from "react";

import {
  pricingActionClassName,
  type PricingActionSize,
  type CompareRow,
  type PlanColumn,
} from "./pricing-helpers";

export function PlanCard({
  name,
  price,
  period,
  badge,
  children,
}: {
  name: string;
  price: ReactNode;
  period?: ReactNode;
  badge?: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="relative flex h-full min-w-0 flex-col border border-border p-6">
      {badge ? <div className="absolute right-6 top-6">{badge}</div> : null}
      <h2 className="pr-28 text-sm font-medium tracking-tight">{name}</h2>
      <div className="mt-3">
        <div className="flex items-baseline gap-1.5">
          <span className="text-3xl font-medium tabular-nums tracking-tight">
            {price}
          </span>
          {period ? (
            <span className="max-w-44 text-sm leading-snug text-muted">
              {period}
            </span>
          ) : null}
        </div>
      </div>
      <div className="mt-3">{children}</div>
    </div>
  );
}

export function PricingCategorySection({
  title,
  id,
  description,
  children,
  columns = "three",
  showHeading = true,
}: {
  title: string;
  id?: string;
  description: string;
  children: ReactNode;
  columns?: "two" | "three" | "four";
  showHeading?: boolean;
}) {
  const headingID = id ?? `${title.toLowerCase().replace(/[^a-z0-9]+/g, "-")}-pricing-category`;
  return (
    <section className={showHeading ? "mt-12 first:mt-8" : ""} aria-labelledby={headingID}>
      <div className={showHeading ? "mb-4 max-w-2xl" : "sr-only"}>
        <h2 id={headingID} className="text-lg font-medium tracking-tight">
          {title}
        </h2>
        <p className="mt-1 text-sm text-muted">{description}</p>
      </div>
      <div className={`grid items-stretch gap-5 ${columns === "two" ? "md:grid-cols-2" : columns === "four" ? "md:grid-cols-2 lg:grid-cols-4" : "md:grid-cols-3"}`}>
        {children}
      </div>
    </section>
  );
}

export function FeatureList({ items }: { items: string[] }) {
  return (
    <ul className="mt-4 space-y-2.5 text-[15px] leading-relaxed">
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
  size = "default",
}: {
  href: string;
  children: ReactNode;
  size?: PricingActionSize;
}) {
  return (
    <a
      href={href}
      className={pricingActionClassName("primary", size)}
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
  size = "default",
}: {
  href: string;
  children: ReactNode;
  size?: PricingActionSize;
}) {
  return (
    <a
      href={href}
      className={pricingActionClassName("secondary", size)}
    >
      {children}
    </a>
  );
}

export function DisabledButton({
  children,
  size = "default",
}: {
  children: ReactNode;
  size?: PricingActionSize;
}) {
  return (
    <button
      className={pricingActionClassName("disabled", size)}
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
  actions,
  showGo = true,
  stickyTopClassName = "top-12",
}: {
  rows: CompareRow[];
  names: Record<PlanColumn, string>;
  prices: Record<PlanColumn, ReactNode>;
  actions?: Partial<Record<PlanColumn, ReactNode>>;
  showGo?: boolean;
  stickyTopClassName?: string;
}) {
  // The header and table use identical tracks at every supported width.
  const gridTemplateColumns = showGo ? "25% repeat(6,12.5%)" : "25% repeat(5,15%)";

  return (
    <div className="max-lg:overflow-x-auto">
      <div className="min-w-[60rem]">
        <div
          className={`sticky ${stickyTopClassName} z-20 grid border-b border-border py-3 text-[15px] [background:var(--pricing-sticky-bg,var(--background))]`}
          style={{ gridTemplateColumns }}
        >
          <div className="pr-4" />
          <ColumnHead name={names.free} price={prices.free} action={actions?.free} />
          {showGo ? <ColumnHead name={names.go} price={prices.go} action={actions?.go} /> : null}
          <ColumnHead name={names.pro} price={prices.pro} action={actions?.pro} />
          <ColumnHead name={names.max} price={prices.max} action={actions?.max} />
          <ColumnHead name={names.team} price={prices.team} action={actions?.team} />
          <ColumnHead
            name={names.enterprise}
            price={prices.enterprise}
            action={actions?.enterprise}
          />
        </div>
        <table className="w-full table-fixed border-separate border-spacing-0 text-[15px]">
          <colgroup>
            <col style={{ width: "25%" }} />
            {showGo ? <col style={{ width: "12.5%" }} /> : null}
            {showGo ? <col style={{ width: "12.5%" }} /> : null}
            <col style={{ width: showGo ? "12.5%" : "15%" }} />
            <col style={{ width: showGo ? "12.5%" : "15%" }} />
            <col style={{ width: showGo ? "12.5%" : "15%" }} />
            <col style={{ width: showGo ? "12.5%" : "15%" }} />
          </colgroup>
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
              {showGo ? <CompareCell value={row.go} /> : null}
              <CompareCell value={row.pro} />
              <CompareCell value={row.max} />
              <CompareCell value={row.team} />
              <CompareCell value={row.enterprise} />
            </tr>
          ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function ColumnHead({
  name,
  price,
  action,
}: {
  name: string;
  price: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="px-4 text-left align-bottom font-medium">
      {name}
      <span className="block text-xs font-normal tabular-nums text-muted">
        {price}
      </span>
      {action ? <div className="mt-2 max-w-32">{action}</div> : null}
    </div>
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
