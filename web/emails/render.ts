// Template registry + HTML rendering for the newsletter CLI scripts.
//
// Scripts stay .ts (no JSX) by going through createElement here. Every
// template renders through MarketingEmailLayout, so the rendered HTML always
// carries the literal {{{RESEND_UNSUBSCRIBE_URL}}} token that Resend
// substitutes per contact at broadcast send time.

import { render } from "@react-email/render";
import { createElement } from "react";

import type { TemplateChoice } from "@/services/newsletter/cli";

import ProductUpdateEmail, {
  type ProductUpdateEmailProps,
} from "./product-update";

export type RenderedEmail = {
  html: string;
  subject: string;
};

export async function renderTemplate(
  template: TemplateChoice,
  overrides: { subject?: string; greetingName?: string } = {},
): Promise<RenderedEmail> {
  switch (template) {
    case "product-update": {
      const props: ProductUpdateEmailProps = {
        ...ProductUpdateEmail.PreviewProps,
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
  }
}
