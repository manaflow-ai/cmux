import type { ReactNode } from "react";

/** Inline, announced error text. Renders nothing for an empty message. */
export function InlineError({
  message,
  className,
}: {
  readonly message: string | null | undefined;
  readonly className?: string;
}) {
  if (!message) return null;
  return (
    <p role="alert" className={`text-xs text-red-600 dark:text-red-400 ${className ?? ""}`}>
      {message}
    </p>
  );
}

/** Secondary explanatory text, used where Hexclave showed a label notice. */
export function SettingsNotice({ children }: { readonly children: ReactNode }) {
  return <p className="text-xs text-muted">{children}</p>;
}

export type BadgeTone = "default" | "outline" | "danger" | "muted";

const badgeToneClass: Record<BadgeTone, string> = {
  default: "border-foreground bg-foreground text-background",
  outline: "border-border text-foreground",
  danger: "border-red-600/40 text-red-600 dark:border-red-400/40 dark:text-red-400",
  muted: "border-transparent bg-code-bg text-muted",
};

export function Badge({
  tone = "default",
  children,
}: {
  readonly tone?: BadgeTone;
  readonly children: ReactNode;
}) {
  return (
    <span
      className={`inline-flex w-fit shrink-0 items-center border px-1.5 py-0.5 text-[11px] leading-none ${badgeToneClass[tone]}`}
    >
      {children}
    </span>
  );
}
