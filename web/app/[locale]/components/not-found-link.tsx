"use client";

import posthog from "posthog-js";

/**
 * Keeps recovery-link analytics tied to the 404 surface. The beacon transport
 * lets the event leave before the internal navigation replaces the page.
 */
export function NotFoundLink({
  href,
  action,
  className,
  children,
}: {
  href: string;
  action: "home" | "docs" | "support";
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      className={className}
      onClick={() =>
        posthog.capture(
          "cmuxterm_404_action_clicked",
          {
            action,
            location: "not_found",
            target: href,
            from: window.location.pathname,
          },
          { transport: "sendBeacon", send_instantly: true },
        )
      }
    >
      {children}
    </a>
  );
}
