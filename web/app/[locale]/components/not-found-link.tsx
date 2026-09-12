"use client";

import posthog from "posthog-js";
import type { AnchorHTMLAttributes } from "react";

type NotFoundLinkProps = Omit<AnchorHTMLAttributes<HTMLAnchorElement>, "href"> & {
  href: string;
  action: "home" | "docs" | "support";
};

/** Tracks a 404 recovery link without sending the page URL to analytics. */
export function NotFoundLink({ action, href, onClick, ...props }: NotFoundLinkProps) {
  return (
    <a
      href={href}
      {...props}
      onClick={(event) => {
        posthog.capture("cmuxterm_404_action_clicked", {
          action,
          location: "not_found",
        });
        onClick?.(event);
      }}
    />
  );
}
