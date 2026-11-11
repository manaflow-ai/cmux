import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

mock.module("@/app/[locale]/components/waitlist-dialog", () => ({
  WaitlistDialog: ({ target }: { target: string | null }) => (
    <div data-waitlist-target={target ?? ""} />
  ),
}));

const { BrowserWaitlistCardAction } = await import(
  "../app/[locale]/(landing)/browser/browser-waitlist-card-action"
);

describe("Browser waitlist card action", () => {
  test("offers a Linux waitlist signup button, not a download link", () => {
    const html = renderToStaticMarkup(
      <BrowserWaitlistCardAction platform="linux" label="Join the Linux waitlist" />,
    );
    expect(html).toContain("<button");
    expect(html).toContain("Join the Linux waitlist");
    expect(html).not.toContain("href=");
    expect(html).not.toContain("/api/download");
  });
});
