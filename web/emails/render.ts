// Template registry + HTML rendering for the newsletter CLI scripts.
//
// Scripts stay .ts (no JSX) by going through createElement here. Every
// template renders through MarketingEmailLayout, so the rendered HTML always
// carries the literal {{{RESEND_UNSUBSCRIBE_URL}}} token that Resend
// substitutes per contact at broadcast send time.

import { render } from "@react-email/render";
import { createElement } from "react";

import type { TemplateChoice } from "@/services/newsletter/cli";
import type { Locale } from "../i18n/routing";

import FoundersFeedbackCallEmail, {
  type FoundersFeedbackCallEmailProps,
} from "./founders-feedback-call";
import ProductUpdateEmail, {
  type ProductUpdateEmailProps,
} from "./product-update";
import {
  DEFAULT_NEWSLETTER_LOCALE,
  loadNewsletterCopy,
  resolveNewsletterLocale,
} from "./newsletter-copy";

export type RenderedEmail = {
  html: string;
  subject: string;
};

export async function renderTemplate(
  template: TemplateChoice,
  overrides: {
    subject?: string;
    greetingName?: string;
    locale?: Locale;
  } = {},
): Promise<RenderedEmail> {
  const locale = resolveNewsletterLocale(
    overrides.locale ?? DEFAULT_NEWSLETTER_LOCALE,
  );
  const copy = await loadNewsletterCopy(locale);
  switch (template) {
    case "product-update": {
      const props: ProductUpdateEmailProps = {
        ...ProductUpdateEmail.PreviewProps,
        ...copy.productUpdate,
        locale,
        footerCopy: copy.footer,
        greetingTemplate: copy.productUpdate.greeting,
        signoff: copy.productUpdate.signoff,
        ...(overrides.greetingName
          ? { greetingName: overrides.greetingName }
          : {}),
      };
      const html = await render(createElement(ProductUpdateEmail, props));
      // A whitespace-only subject override would create a blank-subject
      // broadcast; fall back to the headline instead.
      const subject = overrides.subject?.trim() || props.headline;
      return { html, subject };
    }
    case "founders-feedback-call": {
      const foundersCopy = copy.foundersFeedbackCall;
      const headline = foundersCopy.headline.replaceAll(
        "{releaseVersion}",
        foundersCopy.releaseVersion,
      );
      const props: FoundersFeedbackCallEmailProps = {
        ...FoundersFeedbackCallEmail.PreviewProps,
        ...foundersCopy,
        headline,
        locale,
        footerCopy: copy.footer,
        greetingTemplate: foundersCopy.greeting,
        ...(overrides.greetingName
          ? { greetingName: overrides.greetingName }
          : {}),
      };
      const html = await render(createElement(FoundersFeedbackCallEmail, props));
      const subject = overrides.subject?.trim() || props.headline;
      return { html, subject };
    }
  }
}
