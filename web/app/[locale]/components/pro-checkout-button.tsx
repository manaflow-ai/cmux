"use client";

import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import {
  ctaButtonBase,
  ctaButtonDefaultSize,
  ctaButtonSmallSize,
  ctaButtonStyle,
} from "./cta-styles";

const CHECKOUT_HREF = "/api/billing/checkout";

export function ProCheckoutButton({
  size = "default",
  location = "pro_page",
}: {
  size?: "default" | "sm";
  location?: string;
}) {
  const t = useTranslations("pro");
  return (
    <a
      href={CHECKOUT_HREF}
      onClick={() =>
        posthog.capture("cmuxterm_pro_checkout_clicked", { location })
      }
      className={`${ctaButtonBase} ${
        size === "sm" ? ctaButtonSmallSize : ctaButtonDefaultSize
      }`}
      style={ctaButtonStyle}
    >
      {t("cta")}
    </a>
  );
}
