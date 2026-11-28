import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import {
  PublicationAccessCard,
  type PublicationAccessMessages,
} from "../app/cloud/access/access-card";

const messages: PublicationAccessMessages = {
  title: "You don't have access",
  signIn: "Sign in to cmux",
  signedInAs: "Signed in as {identity}",
  switchAccount: "Switch account",
  invalidTitle: "This access link isn't valid",
  invalidBody: "Return to the shared site and try again.",
  footer: "Access is managed by cmux.",
};

describe("Cloud VM publication access card", () => {
  test("shows the icon, the hostname, and the sign-in action without leaking an account identity", () => {
    const html = renderToStaticMarkup(
      <PublicationAccessCard
        hostname="prickly-lavender-minnow.cmux.sh"
        locale="en"
        messages={messages}
        signInHref="/handler/sign-in?return=opaque"
        view="signed-out"
      />,
    );

    expect(html).toContain('data-publication-access="signed-out"');
    expect(html).toContain("You don&#x27;t have access");
    expect(html).toContain("prickly-lavender-minnow.cmux.sh");
    expect(html).toContain('href="/handler/sign-in?return=opaque"');
    expect(html).toContain("Sign in to cmux");
    expect(html).toContain("Access is managed by cmux.");
    expect(html).toMatch(/<img[^>]*logo\.png/);
    expect(html).not.toContain("Signed in as");
    expect(html).not.toContain("Switch account");
  });

  test("shows the signed-in identity with only an account switch", () => {
    const html = renderToStaticMarkup(
      <PublicationAccessCard
        hostname="prickly-lavender-minnow.cmux.sh"
        identity="viewer@example.com"
        locale="en"
        messages={messages}
        switchAccountHref="/handler/sign-out-and-sign-in?after_auth_return_to=opaque"
        view="signed-in"
      />,
    );

    expect(html).toContain('data-publication-access="signed-in"');
    expect(html).toContain("Signed in as viewer@example.com");
    expect(html).toContain('href="/handler/sign-out-and-sign-in?after_auth_return_to=opaque"');
    expect(html).toContain("Switch account");
    expect(html).not.toContain("Sign in to cmux<");
    expect(html).not.toContain("<form");
    expect(html).not.toContain("Request access");
  });

  test("omits the account switch when no target is provided", () => {
    const html = renderToStaticMarkup(
      <PublicationAccessCard
        hostname="prickly-lavender-minnow.cmux.sh"
        identity="viewer@example.com"
        locale="en"
        messages={messages}
        view="signed-in"
      />,
    );
    expect(html).toContain("Signed in as viewer@example.com");
    expect(html).not.toContain("Switch account");
  });

  test("renders an identity containing replacement patterns literally", () => {
    const html = renderToStaticMarkup(
      <PublicationAccessCard
        hostname="prickly-lavender-minnow.cmux.sh"
        identity="$& $' $1 $$ viewer"
        locale="en"
        messages={messages}
        view="signed-in"
      />,
    );
    expect(html).toContain("Signed in as $&amp; $&#x27; $1 $$ viewer");
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

  test("keeps the invalid state free of any hostname or action", () => {
    const html = renderToStaticMarkup(
      <PublicationAccessCard
        hostname="prickly-lavender-minnow.cmux.sh"
        locale="en"
        messages={messages}
        signInHref="/handler/sign-in?return=opaque"
        view="invalid"
      />,
    );
    expect(html).toContain("This access link isn&#x27;t valid");
    expect(html).toContain("Return to the shared site and try again.");
    expect(html).not.toContain("prickly-lavender-minnow.cmux.sh");
    expect(html).not.toContain("<a ");
  });
});
