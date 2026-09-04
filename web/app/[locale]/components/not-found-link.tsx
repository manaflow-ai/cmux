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
  target,
  rel,
  children,
}: {
  href: string;
  action: "home" | "docs" | "support" | "discord" | "github";
  className?: string;
  target?: React.HTMLAttributeAnchorTarget;
  rel?: string;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      className={className}
      target={target}
      rel={rel}
      onClick={() =>
        posthog.capture(
          "cmuxterm_404_action_clicked",
          {
            action,
            location: "not_found",
            target: href,
            from: "not_found",
          },
          { transport: "sendBeacon", send_instantly: true },
        )
      }
    >
      {children}
    </a>
  );
}
