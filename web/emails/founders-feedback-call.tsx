// cmux Founder's Edition feedback-call invite. The body copy is selected from
// the locale catalog by emails/render.ts; this component only handles layout,
// merge-tag interpolation, and the booking link.

import { Button, Section, Text } from "@react-email/components";

import type { Locale } from "../i18n/routing";
import { MarketingEmailLayout, layoutStyles } from "./components/email-layout";
import {
  DEFAULT_NEWSLETTER_COPY,
  DEFAULT_NEWSLETTER_LOCALE,
} from "./newsletter-copy";

export const FIRST_NAME_GREETING_TOKEN = "{{{contact.first_name|there}}}";

export type FoundersFeedbackCallEmailProps = {
  previewText: string;
  headline: string;
  locale: Locale;
  footerCopy: { receiptNotice: string; unsubscribe: string };
  greetingTemplate: string;
  greetingName?: string;
  releaseVersion: string;
  paragraphs: string[];
  bookingUrl: string;
  ctaText: string;
  signoff: string;
};

function interpolate(
  value: string,
  variables: { releaseVersion: string; bookingUrl: string },
): string {
  return value
    .replaceAll("{releaseVersion}", variables.releaseVersion)
    .replaceAll("{bookingUrl}", variables.bookingUrl);
}

export default function FoundersFeedbackCallEmail({
  previewText,
  locale,
  footerCopy,
  greetingTemplate,
  greetingName,
  releaseVersion,
  paragraphs,
  bookingUrl,
  ctaText,
  signoff,
}: FoundersFeedbackCallEmailProps) {
  const greeting = greetingTemplate.replace(
    "{name}",
    greetingName?.trim() || FIRST_NAME_GREETING_TOKEN,
  );
  const renderedParagraphs = paragraphs.map((paragraph) =>
    interpolate(paragraph, { releaseVersion, bookingUrl }),
  );
  const intro = renderedParagraphs[0] ?? "";
  const bodyParagraphs = renderedParagraphs.slice(1);

  return (
    <MarketingEmailLayout
      previewText={previewText}
      locale={locale}
      footerCopy={footerCopy}
      intro={
        <>
          <Text style={{ ...bodyText, margin: "0 0 12px" }}>{greeting}</Text>
          <Text style={{ ...bodyText, margin: 0 }}>{intro}</Text>
        </>
      }
    >
      {bodyParagraphs.map((paragraph, index) => (
        <Text key={`${paragraph}-${index}`} style={bodyText}>
          {index === 2 ? (
            <>
              {paragraph.replace(bookingUrl, "")} {" "}
              <a
                href={bookingUrl}
                style={{ color: layoutStyles.ink, fontWeight: 600 }}
              >
                {bookingUrl}
              </a>
            </>
          ) : (
            paragraph
          )}
        </Text>
      ))}
      <Section style={{ paddingTop: "8px" }}>
        <Button
          href={bookingUrl}
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

FoundersFeedbackCallEmail.PreviewProps = {
  ...DEFAULT_NEWSLETTER_COPY.foundersFeedbackCall,
  locale: DEFAULT_NEWSLETTER_LOCALE,
  footerCopy: DEFAULT_NEWSLETTER_COPY.footer,
  greetingTemplate: DEFAULT_NEWSLETTER_COPY.foundersFeedbackCall.greeting,
} satisfies FoundersFeedbackCallEmailProps;

