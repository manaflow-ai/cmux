import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import {
  PublicationAccessCard,
  type PublicationAccessMessages,
} from "../app/cloud/access/access-card";

const messages: PublicationAccessMessages = {
  eyebrow: "cmux cloud",
  title: "You don't have access",
  signedOutBody: "Sign in to cmux to view this site.",
  signIn: "Sign in to cmux",
  signedInAs: "Signed in as {identity}",
  invalidTitle: "This access link isn't valid",
  invalidBody: "Return to the shared site and try again.",
  footer: "Access is managed by cmux.",
};

describe("Cloud VM publication access card", () => {
  test("shows the sign-in action without leaking an account identity", () => {
    const html = renderToStaticMarkup(
      <PublicationAccessCard
        hostname="preview.example.com"
        locale="en"
        messages={messages}
        signInHref="/handler/sign-in?return=opaque"
        view="signed-out"
      />,
    );

    expect(html).toContain('data-publication-access="signed-out"');
    expect(html).toContain("You don&#x27;t have access");
    expect(html).toContain("Sign in to cmux to view this site.");
    expect(html).toContain('href="/handler/sign-in?return=opaque"');
    expect(html).not.toContain("Signed in as");
  });

  test("shows the signed-in identity without an access action", () => {
    const html = renderToStaticMarkup(
      <PublicationAccessCard
        hostname="preview.example.com"
        identity="viewer@example.com"
        locale="en"
        messages={messages}
        view="signed-in"
      />,
    );

    expect(html).toContain('data-publication-access="signed-in"');
    expect(html).toContain("Signed in as viewer@example.com");
    expect(html).not.toContain("<form");
    expect(html).not.toContain("Request access");
  });

  test("marks Arabic copy as right-to-left", () => {
    const html = renderToStaticMarkup(
      <PublicationAccessCard
        locale="ar"
        messages={messages}
        view="invalid"
      />,
    );
    expect(html).toContain('dir="rtl"');
    expect(html).toContain('data-publication-access="invalid"');
  });
});
