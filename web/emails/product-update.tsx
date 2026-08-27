// cmux product-update broadcast template.
//
// Authored and previewed with the react-email dev server (`bun run
// email:dev`), drafted into Resend with `bun run email:draft`, and
// spot-checked in a real inbox with `bun run email:test` (which only sends
// to austin@manaflow.ai). The audience send itself is a human click in the
// Resend dashboard.
//
// The opening line personalizes via Resend's contact merge tags ("Hey,
// {{{contact.first_name|there}}}.") ahead of a fixed founders-voice intro
// ("Austin from cmux here."). The segment sync populates first_name on each
// contact, and the merge tag's explicit "there" fallback means a broadcast
// never renders "Hey, ," or "Hey, undefined.".

import { Button, Img, Link, Section, Text } from "@react-email/components";

import type { Locale } from "../i18n/routing";
import { MarketingEmailLayout, layoutStyles } from "./components/email-layout";
import {
  DEFAULT_NEWSLETTER_LOCALE,
  DEFAULT_NEWSLETTER_COPY,
  type NewsletterSectionCopy,
} from "./newsletter-copy";

export const FIRST_NAME_GREETING_TOKEN = "{{{contact.first_name|there}}}";

export type ProductUpdateSection = NewsletterSectionCopy;

export type ProductUpdateEmailProps = {
  previewText: string;
  headline: string;
  locale: Locale;
  footerCopy: { receiptNotice: string; unsubscribe: string };
  greetingTemplate: string;
  signoff: string;
  // Overridable so one-off test sends (where merge tags are not substituted)
  // can show a concrete name; broadcasts keep the merge-tag default.
  greetingName?: string;
  // One-line summary shown under the greeting, e.g. "This week, we shipped
  // X, Y, and Z. Here's what's new:".
  intro?: string;
  sections: ProductUpdateSection[];
  ctaText?: string;
  ctaUrl?: string;
};

export default function ProductUpdateEmail({
  previewText,
  headline,
  locale,
  footerCopy,
  greetingTemplate,
  signoff,
  greetingName,
  intro,
  sections,
  ctaText,
  ctaUrl,
}: ProductUpdateEmailProps) {
  // Normalize at the rendering boundary: a missing, empty, or whitespace-only
  // override keeps the Resend merge tag and its explicit fallback intact.
  const greetingNameOrToken =
    greetingName?.trim() || FIRST_NAME_GREETING_TOKEN;
  const greeting = greetingTemplate.replace("{name}", greetingNameOrToken);
  return (
    <MarketingEmailLayout
      previewText={previewText}
      locale={locale}
      footerCopy={footerCopy}
      intro={
        <>
          <Text style={{ ...bodyText, margin: "0 0 12px" }}>
            {greeting}
          </Text>
          <Text style={{ ...bodyText, margin: 0 }}>{intro ?? headline}</Text>
        </>
      }
    >
      {sections.map((section, index) => (
        <Section
          key={section.title}
          style={{ paddingTop: index > 0 ? "24px" : 0 }}
        >
          <Text
            style={{
              margin: "0 0 8px",
              fontFamily: layoutStyles.textStack,
              fontSize: "18px",
              fontWeight: 700,
              lineHeight: "24px",
              color: layoutStyles.ink,
            }}
          >
            {section.title}
          </Text>
          {section.imageUrl ? (
            <Section style={{ padding: "4px 0 16px" }}>
              <Img
                src={section.imageUrl}
                alt={section.imageAlt ?? ""}
                width="100%"
                style={{
                  width: "100%",
                  borderRadius: "12px",
                  border: `1px solid ${layoutStyles.border}`,
                  display: "block",
                }}
              />
            </Section>
          ) : null}
          <Text style={bodyText}>
            {section.body}
            {section.linkText && section.linkUrl ? (
              <>
                {" "}
                <Link
                  href={section.linkUrl}
                  style={{
                    color: layoutStyles.ink,
                    fontWeight: 600,
                    textDecoration: "underline",
                  }}
                >
                  {section.linkText}
                </Link>
              </>
            ) : null}
          </Text>
          {section.bullets && section.bullets.length > 0 ? (
            <ul style={{ margin: "0 0 12px", padding: "0 0 0 20px" }}>
              {section.bullets.map((bullet) => (
                <li key={bullet} style={{ ...bodyText, margin: "0 0 6px" }}>
                  {bullet}
                </li>
              ))}
            </ul>
          ) : null}
        </Section>
      ))}
      {ctaText && ctaUrl ? (
        <Section style={{ paddingTop: "24px" }}>
          <Button
            href={ctaUrl}
            style={{
              backgroundColor: layoutStyles.ink,
              color: "#ffffff",
              fontFamily: layoutStyles.textStack,
              fontWeight: 600,
              fontSize: "14px",
              padding: "13px 22px",
              borderRadius: "10px",
              textDecoration: "none",
            }}
          >
            {ctaText}
          </Button>
        </Section>
      ) : null}
      <Text style={{ ...bodyText, margin: "24px 0 0" }}>
        {signoff.split("\n").map((line, index) => (
          <span key={`${line}-${index}`}>
            {index > 0 ? <br /> : null}
            {line}
          </span>
        ))}
      </Text>
    </MarketingEmailLayout>
  );
}

const bodyText = {
  fontFamily: layoutStyles.textStack,
  margin: "0 0 12px",
  fontSize: "15px",
  lineHeight: "24px",
  color: layoutStyles.bodyInk,
} as const;

// Sample content shown by the react-email preview server and used by the
// email:test / email:draft scripts as a starting point.
ProductUpdateEmail.PreviewProps = {
  ...DEFAULT_NEWSLETTER_COPY.productUpdate,
  locale: DEFAULT_NEWSLETTER_LOCALE,
  footerCopy: DEFAULT_NEWSLETTER_COPY.footer,
  greetingTemplate: DEFAULT_NEWSLETTER_COPY.productUpdate.greeting,
  signoff: DEFAULT_NEWSLETTER_COPY.productUpdate.signoff,
} satisfies ProductUpdateEmailProps;
