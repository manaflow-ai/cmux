import type { ReactNode } from "react";

type CalloutType = "info" | "note" | "tip" | "check" | "warn" | "danger";

const calloutStyles: Record<CalloutType, { frame: string; icon: string }> = {
  info: {
    frame: "border-sky-500/20 bg-sky-500/[0.06] dark:border-sky-400/20 dark:bg-sky-400/[0.06]",
    icon: "text-sky-600 dark:text-sky-400",
  },
  note: {
    frame: "border-border bg-code-bg/60",
    icon: "text-muted",
  },
  tip: {
    frame: "border-emerald-500/20 bg-emerald-500/[0.06] dark:border-emerald-400/20 dark:bg-emerald-400/[0.06]",
    icon: "text-emerald-600 dark:text-emerald-400",
  },
  check: {
    frame: "border-green-500/20 bg-green-500/[0.06] dark:border-green-400/20 dark:bg-green-400/[0.06]",
    icon: "text-green-600 dark:text-green-400",
  },
  warn: {
    frame: "border-amber-500/25 bg-amber-500/[0.07] dark:border-amber-400/20 dark:bg-amber-400/[0.06]",
    icon: "text-amber-600 dark:text-amber-400",
  },
  danger: {
    frame: "border-red-500/20 bg-red-500/[0.06] dark:border-red-400/20 dark:bg-red-400/[0.06]",
    icon: "text-red-600 dark:text-red-400",
  },
};

function CalloutIcon({ type }: { type: CalloutType }) {
  const common = {
    width: 16,
    height: 16,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 2,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true,
  };
  switch (type) {
    case "tip":
      return (
        <svg {...common}>
          <path d="M9 18h6M10 22h4" />
          <path d="M12 2a7 7 0 0 0-4 12.7V17h8v-2.3A7 7 0 0 0 12 2z" />
        </svg>
      );
    case "check":
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="10" />
          <path d="m8 12 3 3 5-6" />
        </svg>
      );
    case "warn":
    case "danger":
      return (
        <svg {...common}>
          <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
          <path d="M12 9v4M12 17h.01" />
        </svg>
      );
    case "note":
      return (
        <svg {...common}>
          <path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z" />
          <path d="M14 2v6h6M8 13h8M8 17h5" />
        </svg>
      );
    default:
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="10" />
          <path d="M12 16v-4M12 8h.01" />
        </svg>
      );
  }
}

/** Mintlify-style admonition: a tinted, rounded frame with a leading icon. */
export function Callout({
  type = "info",
  children,
}: {
  type?: CalloutType;
  children: ReactNode;
}) {
  const style = calloutStyles[type];

  return (
    <div
      className={`${style.frame} not-prose my-5 flex gap-3 rounded-2xl border px-5 py-4 text-[14px] leading-6 text-foreground/85`}
    >
      <span className={`${style.icon} mt-1 shrink-0`}>
        <CalloutIcon type={type} />
      </span>
      <div className="min-w-0 [&>p:last-child]:mb-0 [&>p]:mb-2">{children}</div>
    </div>
  );
}
