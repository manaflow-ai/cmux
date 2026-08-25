import { loadMessages } from "../i18n/messages";
import type { Locale } from "../i18n/routing";
import enMessages from "../messages/en.json";

export type NewsletterSectionCopy = {
  title: string;
  body: string;
  bullets?: string[];
  linkText?: string;
  linkUrl?: string;
  imageUrl?: string;
  imageAlt?: string;
};

export type NewsletterCopy = {
  footer: {
    receiptNotice: string;
    unsubscribe: string;
  };
  productUpdate: {
    previewText: string;
    headline: string;
    greeting: string;
    intro: string;
    sections: NewsletterSectionCopy[];
    signoff: string;
  };
  foundersFeedbackCall: {
    previewText: string;
    headline: string;
    greeting: string;
    releaseVersion: string;
    paragraphs: string[];
    bookingUrl: string;
    ctaText: string;
    signoff: string;
  };
};

type MessageCatalog = {
  emails?: { newsletter?: NewsletterCopy };
};

export const DEFAULT_NEWSLETTER_LOCALE: Locale = "en";
export const DEFAULT_NEWSLETTER_COPY = (enMessages as {
  emails: { newsletter: NewsletterCopy };
}).emails.newsletter;

export async function loadNewsletterCopy(
  locale: Locale = DEFAULT_NEWSLETTER_LOCALE,
): Promise<NewsletterCopy> {
  const catalog = (await loadMessages(locale)) as MessageCatalog;
  const copy = catalog.emails?.newsletter;
  if (!copy) {
    throw new Error("Newsletter copy is missing from the selected locale");
  }
  return copy;
}
