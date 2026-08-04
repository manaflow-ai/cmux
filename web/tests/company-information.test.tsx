import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import sitemap from "../app/sitemap";
import CompanyInformationPage, {
  metadata,
} from "../app/[locale]/(legal)/company-information/page";
import { agentReadablePages } from "../app/lib/agent-page-paths";

test("publishes the legal entity, contact, address, and both domains", () => {
  const html = renderToStaticMarkup(<CompanyInformationPage />);

  expect(html).toContain("Manaflow, Inc.");
  expect(html).toContain("18428 Vantage Pointe Dr");
  expect(html).toContain("Rowland Heights");
  expect(html).toContain("91748-5142");
  expect(html).toContain("founders@manaflow.com");
  expect(html).toContain("manaflow.com");
  expect(html).toContain("cmux.com");
  expect(html).toContain("application/ld+json");
});

test("keeps the direct page out of discovery indexes", () => {
  const urls = sitemap()
    .map((entry) => entry.url)
    .filter((url) => url.endsWith("/company-information"));

  expect(urls).toEqual([]);
  expect(
    agentReadablePages.some((page) => page.path === "/company-information"),
  ).toBe(false);
  expect(metadata.robots).toEqual({ index: false, follow: false });
});
