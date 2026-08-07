// Shared branded layout for every cmux marketing/broadcast email.
//
// Branding lives here in exactly one place: header wordmark, typography,
// spacing, colors that hold up under email-client dark modes, and the
// footer. Individual templates compose this layout and provide body content
// only.
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
  Img,
  Link,
  Preview,
  Section,
  Text,
} from "@react-email/components";
import type * as React from "react";

// Resend substitutes this at broadcast send time with the per-contact
// unsubscribe URL. Triple braces are Resend's raw-merge-tag syntax; the
// literal token must appear verbatim in the rendered HTML.
export const RESEND_UNSUBSCRIBE_TOKEN = "{{{RESEND_UNSUBSCRIBE_URL}}}";

// Sender's physical postal address, required by CAN-SPAM in every marketing
// email. Kept in sync with web/app/[locale]/(legal)/company-information.
export const COMPANY_POSTAL_ADDRESS =
  "Manaflow, Inc. · 18428 Vantage Pointe Dr, Rowland Heights, CA 91748-5142";

// Palette lifted from the marketing site (web/app/[locale]/theme-colors.ts):
// near-black ink on a near-white page. Emails render on a light card that
// most dark-mode clients leave alone, with ink colors that stay legible if a
// client force-inverts.
const PAGE_BACKGROUND = "#fafafa";
const CARD_BACKGROUND = "#ffffff";
const INK = "#0a0a0a";
const MUTED = "#6b7280";
const BORDER = "#e5e5e5";

const MONO_STACK =
  'ui-monospace, "SF Mono", "Geist Mono", Menlo, Consolas, monospace';
const TEXT_STACK =
  '-apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif';

export const layoutStyles = {
  ink: INK,
  muted: MUTED,
  border: BORDER,
  monoStack: MONO_STACK,
  textStack: TEXT_STACK,
} as const;

export function MarketingEmailLayout({
  previewText,
  children,
}: {
  previewText: string;
  children: React.ReactNode;
}) {
  return (
    <Html lang="en">
      <Head />
      <Preview>{previewText}</Preview>
      <Body
        style={{
          margin: 0,
          backgroundColor: PAGE_BACKGROUND,
          fontFamily: TEXT_STACK,
          color: INK,
        }}
      >
        <Container
          style={{
            maxWidth: "560px",
            margin: "0 auto",
            padding: "32px 16px",
          }}
        >
          <Section style={{ paddingBottom: "20px" }}>
            <Link href="https://cmux.com" style={{ textDecoration: "none" }}>
              <Img
                src="https://cmux.com/logo.png"
                alt="cmux"
                width="36"
                height="36"
                style={{ borderRadius: "8px", display: "inline-block" }}
              />
            </Link>
            <Text
              style={{
                margin: "8px 0 0",
                fontFamily: MONO_STACK,
                fontSize: "14px",
                letterSpacing: "0.02em",
                color: INK,
              }}
            >
              cmux
            </Text>
          </Section>
          <Section
            style={{
              backgroundColor: CARD_BACKGROUND,
              border: `1px solid ${BORDER}`,
              borderRadius: "12px",
              padding: "28px",
            }}
          >
            {children}
          </Section>
          <Section style={{ paddingTop: "20px" }}>
            <Text
              style={{
                margin: "0 0 6px",
                fontSize: "12px",
                lineHeight: "18px",
                color: MUTED,
              }}
            >
              You are receiving this because you signed up for cmux or bought
              cmux Founder&apos;s Edition.
            </Text>
            <Text
              style={{
                margin: "0 0 6px",
                fontSize: "12px",
                lineHeight: "18px",
                color: MUTED,
              }}
            >
              {/* CAN-SPAM requires the sender's valid physical postal
                  address in every commercial email. This is the registered
                  business address from the company-information legal page. */}
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
                Unsubscribe
              </Link>
            </Text>
            <Hr
              style={{
                borderColor: BORDER,
                borderTopWidth: "1px",
                margin: "16px 0 0",
              }}
            />
          </Section>
        </Container>
      </Body>
    </Html>
  );
}
