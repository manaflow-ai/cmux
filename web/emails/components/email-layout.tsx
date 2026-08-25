// Shared branded layout for every cmux marketing/broadcast email.
//
// Branding lives here in exactly one place: header wordmark, typography,
// spacing, colors that hold up under email-client dark modes, and the
// footer. Individual templates compose this layout and provide the "intro"
// (greeting + summary) and "children" (the update content) — both render
// directly on one continuous background, no separate card surface.
//
// Layout pattern: one flat background. Logo + wordmark, greeting, and the
// update content all sit on that same surface, flowing continuously with no
// dividers between story blocks; the single SectionDivider sits right above
// the legal footer, the one place a visual break belongs.
//
// Typography matches the cmux marketing site (web/app/layout.tsx), which
// loads Geist via next/font/google as --font-sans for every page, including
// headlines; font-mono only shows up in terminal/code-flavored contexts
// (web/app/[locale]/(landing)/tui, /docs, /assets), never in headings or
// body copy. This layout mirrors that: Geist Sans everywhere, no
// monospace. Since most email clients ignore @font-face, the real Geist
// woff2 (hosted on jsDelivr from the published `geist` npm package, the
// same font family the site embeds) is a progressive enhancement; the
// fallback stack is a close visual match for clients that skip it.
//
// The footer unconditionally renders the Resend unsubscribe merge tag
// {{{RESEND_UNSUBSCRIBE_URL}}}. That is a structural guarantee, not a
// convention: templates cannot opt out, so it is impossible to author a
// cmux marketing email without a working unsubscribe link (CAN-SPAM
// requires one). web/tests/newsletter-email-template.test.ts pins this.
//
// This layout is for marketing/broadcast mail only. The transactional
// Founder's Edition welcome (app/api/stripe/founders-welcome) is plain text
// on purpose and does not use it.

import {
  Body,
  Container,
  Head,
  Hr,
  Html,
  Link,
  Preview,
  Section,
  Text,
} from "@react-email/components";
import { Font } from "@react-email/font";
import type * as React from "react";
import type { Locale } from "../../i18n/routing";

// Resend substitutes this at broadcast send time with the per-contact
// unsubscribe URL. Triple braces are Resend's raw-merge-tag syntax; the
// literal token must appear verbatim in the rendered HTML.
export const RESEND_UNSUBSCRIBE_TOKEN = "{{{RESEND_UNSUBSCRIBE_URL}}}";

// Sender's physical postal address, required by CAN-SPAM in every marketing
// email.
export const COMPANY_POSTAL_ADDRESS =
  "Manaflow, Inc. · 501 2nd Street, Suite 350, San Francisco, CA 94107";

const INK = "#0a0a0a";
const BODY_INK = "#1f2430";
const MUTED = "#6b7280";
const BORDER = "rgba(10, 10, 10, 0.1)";

const GEIST_SANS = "Geist";
// Same fallback family next/font/google uses when Geist itself has not
// loaded yet, plus common webmail-safe sans stacks so non-Apple/Windows
// clients still land on a comparable grotesque instead of a serif default.
const TEXT_STACK = `${GEIST_SANS}, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif`;

export const layoutStyles = {
  ink: INK,
  bodyInk: BODY_INK,
  muted: MUTED,
  border: BORDER,
  textStack: TEXT_STACK,
} as const;

const GEIST_CDN_BASE =
  "https://cdn.jsdelivr.net/npm/geist@1.7.2/dist/fonts/geist-sans";

function GeistFontFaces() {
  return (
    <>
      <Font
        fontFamily={GEIST_SANS}
        fallbackFontFamily="Helvetica"
        webFont={{ url: `${GEIST_CDN_BASE}/Geist-Regular.woff2`, format: "woff2" }}
        fontWeight={400}
        fontStyle="normal"
      />
      <Font
        fontFamily={GEIST_SANS}
        fallbackFontFamily="Helvetica"
        webFont={{ url: `${GEIST_CDN_BASE}/Geist-Medium.woff2`, format: "woff2" }}
        fontWeight={500}
        fontStyle="normal"
      />
      <Font
        fontFamily={GEIST_SANS}
        fallbackFontFamily="Helvetica"
        webFont={{ url: `${GEIST_CDN_BASE}/Geist-SemiBold.woff2`, format: "woff2" }}
        fontWeight={600}
        fontStyle="normal"
      />
      <Font
        fontFamily={GEIST_SANS}
        fallbackFontFamily="Helvetica"
        webFont={{ url: `${GEIST_CDN_BASE}/Geist-Bold.woff2`, format: "woff2" }}
        fontWeight={700}
        fontStyle="normal"
      />
    </>
  );
}

export function MarketingEmailLayout({
  previewText,
  locale,
  footerCopy,
  intro,
  children,
}: {
  previewText: string;
  locale: Locale;
  footerCopy: {
    receiptNotice: string;
    unsubscribe: string;
  };
  // Greeting + summary line(s), rendered directly on the gradient
  // background right below the header.
  intro: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <Html lang={locale} dir={locale === "ar" ? "rtl" : "ltr"}>
      <Head>
        <GeistFontFaces />
      </Head>
      <Preview>{previewText}</Preview>
      <Body style={{ margin: 0 }}>
        {/* No background color anywhere: this renders on whatever the
            email client's own default is (plain white in almost every
            client), not a color this template imposes. */}
        <table
          role="presentation"
          width="100%"
          cellPadding={0}
          cellSpacing={0}
          style={{ width: "100%" }}
        >
          <tbody>
            <tr>
              <td>
                <Container
                  style={{
                    maxWidth: "640px",
                    margin: 0,
                    padding: 0,
                    fontFamily: TEXT_STACK,
                  }}
                >
                  <Section style={{ paddingBottom: "24px" }}>{intro}</Section>

                  {children}

                  <SectionDivider />

                  <Section>
                    <Text
                      style={{
                        margin: "0 0 6px",
                        fontSize: "12px",
                        lineHeight: "18px",
                        color: MUTED,
                      }}
                    >
                      {footerCopy.receiptNotice}
                    </Text>
                    <Text
                      style={{
                        margin: "0 0 6px",
                        fontSize: "12px",
                        lineHeight: "18px",
                        color: MUTED,
                      }}
                    >
                      {/* CAN-SPAM requires the sender's valid physical
                          postal address in every commercial email. */}
                      {COMPANY_POSTAL_ADDRESS}
                    </Text>
                    <Text
                      style={{
                        margin: 0,
                        fontSize: "12px",
                        lineHeight: "18px",
                        color: MUTED,
                      }}
                    >
                      <Link
                        href={RESEND_UNSUBSCRIBE_TOKEN}
                        style={{ color: MUTED, textDecoration: "underline" }}
                      >
                        {footerCopy.unsubscribe}
                      </Link>
                    </Text>
                  </Section>
                </Container>
              </td>
            </tr>
          </tbody>
        </table>
      </Body>
    </Html>
  );
}

// Thin divider used between story blocks (matches the hairline rule
// between sections in the reference newsletter layout).
export function SectionDivider() {
  return (
    <Hr style={{ borderColor: BORDER, borderTopWidth: "1px", margin: "24px 0" }} />
  );
}
