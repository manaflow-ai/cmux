"use client";

import posthog from "posthog-js";
import { Link, usePathname } from "@/i18n/navigation";

// Localized internal link that records a PostHog click event, so we can see how
// many clicks each guide / landing page gets and where they came from.
export function TrackedLink({
  href,
  event,
  className,
  children,
}: {
  href: string;
  event: string;
  className?: string;
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  return (
    <Link
      href={href}
      className={className}
      onClick={() => posthog.capture(event, { target: href, from: pathname })}
    >
      {children}
    </Link>
  );
}
