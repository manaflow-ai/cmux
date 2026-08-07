// cmux product-update broadcast template.
//
// Authored and previewed with the react-email dev server (`bun run
// email:dev`), drafted into Resend with `bun run email:draft`, and
// spot-checked in a real inbox with `bun run email:test` (which only sends
// to austin@manaflow.ai). The audience send itself is a human click in the
// Resend dashboard.
//
// The greeting personalizes via Resend's contact merge tags. The segment
// sync populates first_name on each contact, and
// {{{contact.first_name|there}}} falls back to "there" for contacts without
// one, so a broadcast never renders "Hi ," or "Hi undefined,".

import { Button, Heading, Link, Section, Text } from "@react-email/components";

import {
  MarketingEmailLayout,
  layoutStyles,
} from "./components/email-layout";

export const FIRST_NAME_GREETING_TOKEN = "{{{contact.first_name|there}}}";

export type ProductUpdateSection = {
  title: string;
  body: string;
  linkText?: string;
  linkUrl?: string;
};

export type ProductUpdateEmailProps = {
  previewText: string;
  headline: string;
  // Overridable so one-off test sends (where merge tags are not substituted)
  // can show a concrete name; broadcasts keep the merge-tag default.
  greetingName?: string;
  intro?: string;
  sections: ProductUpdateSection[];
  ctaText?: string;
  ctaUrl?: string;
};

export default function ProductUpdateEmail({
  previewText,
  headline,
  greetingName,
  intro,
  sections,
  ctaText,
  ctaUrl,
}: ProductUpdateEmailProps) {
  // Normalize at the rendering boundary: a missing, empty, or
  // whitespace-only override still yields a natural greeting instead of
  // "Hi ,".
  const greeting = greetingName?.trim() || FIRST_NAME_GREETING_TOKEN;
  return (
    <MarketingEmailLayout previewText={previewText}>
      <Heading
        as="h1"
        style={{
          margin: "0 0 16px",
          fontFamily: layoutStyles.monoStack,
          fontSize: "22px",
          lineHeight: "30px",
          color: layoutStyles.ink,
        }}
      >
        {headline}
      </Heading>
      <Text style={bodyText}>{`Hi ${greeting},`}</Text>
      {intro ? <Text style={bodyText}>{intro}</Text> : null}
      {sections.map((section) => (
        <Section key={section.title} style={{ paddingTop: "8px" }}>
          <Text
            style={{
              margin: "0 0 4px",
              fontFamily: layoutStyles.monoStack,
              fontSize: "14px",
              fontWeight: 600,
              color: layoutStyles.ink,
            }}
          >
            {section.title}
          </Text>
          <Text style={{ ...bodyText, margin: "0 0 8px" }}>
            {section.body}
            {section.linkText && section.linkUrl ? (
              <>
                {" "}
                <Link
                  href={section.linkUrl}
                  style={{
                    color: layoutStyles.ink,
                    textDecoration: "underline",
                  }}
                >
                  {section.linkText}
                </Link>
              </>
            ) : null}
          </Text>
        </Section>
      ))}
      {ctaText && ctaUrl ? (
        <Section style={{ paddingTop: "16px" }}>
          <Button
            href={ctaUrl}
            style={{
              backgroundColor: layoutStyles.ink,
              color: "#ffffff",
              fontFamily: layoutStyles.monoStack,
              fontSize: "14px",
              padding: "12px 20px",
              borderRadius: "8px",
              textDecoration: "none",
            }}
          >
            {ctaText}
          </Button>
        </Section>
      ) : null}
      <Text style={{ ...bodyText, margin: "24px 0 0" }}>
        Best,
        <br />
        Austin and Lawrence
      </Text>
    </MarketingEmailLayout>
  );
}

const bodyText = {
  margin: "0 0 12px",
  fontSize: "15px",
  lineHeight: "24px",
  color: layoutStyles.ink,
} as const;

// Sample content shown by the react-email preview server and used by the
// email:test / email:draft scripts as a starting point.
ProductUpdateEmail.PreviewProps = {
  previewText: "Faster terminals, iOS beta, and a smarter sidebar.",
  headline: "cmux update: July 2026",
  intro:
    "Here is what shipped in cmux since the last update. Everything below is live today.",
  sections: [
    {
      title: "iOS beta",
      body: "Drive your Mac's cmux workspaces from your phone, including agent sessions and notifications.",
      linkText: "Read the announcement",
      linkUrl: "https://cmux.com/blog",
    },
    {
      title: "Faster typing under load",
      body: "Keystroke latency stays flat even with dozens of live terminal splits.",
    },
    {
      title: "Session restore",
      body: "cmux restore brings back your whole workspace after a reboot, shell-free.",
    },
  ],
  ctaText: "Download the latest cmux",
  ctaUrl: "https://cmux.com",
} satisfies ProductUpdateEmailProps;
