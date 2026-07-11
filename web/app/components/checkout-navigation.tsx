"use client";

import { useCallback, useState, type CSSProperties, type MouseEvent, type ReactNode } from "react";

import { pricingActionClassName, type PricingActionSize } from "./pricing-shared";

const CHECKOUT_PATH = "/api/billing/checkout";

// Intercepts a checkout link click: instead of navigating to the checkout route
// (which flashes a blank page while it builds the Stripe session server-side),
// fetch the resolved destination as JSON and redirect the browser straight
// there, keeping a spinner on the button until the page leaves.
export function useCheckoutRedirect() {
  const [pending, setPending] = useState(false);

  const start = useCallback(
    (href: string, event?: MouseEvent<HTMLAnchorElement>) => {
      // Let anything that isn't a plain left-click fall through to the browser's
      // default navigation (new tab, download, etc.), and only intercept the
      // checkout route so non-checkout hrefs (e.g. the download fallback) behave
      // as ordinary links.
      if (
        event &&
        (event.defaultPrevented ||
          event.button !== 0 ||
          event.metaKey ||
          event.ctrlKey ||
          event.shiftKey ||
          event.altKey)
      ) {
        return;
      }
      if (!href.startsWith(CHECKOUT_PATH)) return;
      event?.preventDefault();
      if (pending) return;
      setPending(true);

      const separator = href.includes("?") ? "&" : "?";
      void fetch(`${href}${separator}format=json`, {
        headers: { accept: "application/json" },
      })
        .then((response) => response.json())
        .then((data: unknown) => {
          const url =
            data && typeof data === "object" && typeof (data as { url?: unknown }).url === "string"
              ? (data as { url: string }).url
              : href;
          window.location.assign(url);
        })
        .catch(() => {
          // Network/JSON failure: fall back to the plain navigation, which the
          // route still handles with a server-side 302.
          window.location.assign(href);
        });
    },
    [pending],
  );

  return { pending, start };
}

export function CheckoutSpinner() {
  return (
    <svg
      className="animate-spin"
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
      style={{ display: "inline-block", verticalAlign: "-2px" }}
    >
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeOpacity="0.3" strokeWidth="3" />
      <path d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
    </svg>
  );
}

const PRIMARY_LINK_STYLE: CSSProperties = {
  color: "var(--button-foreground, var(--background))",
  textDecoration: "none",
};

// A "Get Pro" / "Get Team" checkout button: renders as an anchor (so it works
// without JS and supports open-in-new-tab), but on a plain click it shows a
// spinner and redirects straight to Stripe.
export function CheckoutButton({
  href,
  children,
  size = "default",
  onClick,
}: {
  href: string;
  children: ReactNode;
  size?: PricingActionSize;
  onClick?: (event: MouseEvent<HTMLAnchorElement>) => void;
}) {
  const { pending, start } = useCheckoutRedirect();
  return (
    <a
      href={href}
      onClick={(event) => {
        onClick?.(event);
        start(href, event);
      }}
      aria-busy={pending}
      className={pricingActionClassName("primary", size)}
      style={{ ...PRIMARY_LINK_STYLE, pointerEvents: pending ? "none" : undefined }}
    >
      {pending ? <CheckoutSpinner /> : children}
    </a>
  );
}
