// The Page Info bubble opened again on a site draws that site's last cookie summary while the host
// reads it again (siteDataMemory.ts), not a "Loading…" row; the host's read replaces it.
import { beforeEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { PageInfoBubble } from "../src/browser-chrome/page-info/PageInfoBubble";
import type { PageInfoModel } from "../src/browser-chrome/page-info/model";
import { forgetSiteData, withLastSiteData } from "../src/browser-chrome/page-info/siteDataMemory";

const model = (displayName: string, siteData: PageInfoModel["siteData"]): PageInfoModel =>
  ({
    site: { kind: "web", connection: "secure", displayName },
    page: { type: "cookies" },
    permissions: [],
    siteData,
    certificate: null,
  }) as PageInfoModel;

const draw = (m: PageInfoModel) => renderToStaticMarkup(<PageInfoBubble model={m} onCommand={() => {}} />);

beforeEach(() => forgetSiteData());

test("a site read once draws its last summary on the next opening, not Loading", () => {
  const cold = withLastSiteData(model("example.com", null));
  expect(cold.siteData).toBeNull();
  expect(draw(cold)).toContain("pageInfo.loading");

  withLastSiteData(model("example.com", { firstPartyCookies: 14, siteCount: 3, thirdPartyPolicy: "allowed" }));

  const warm = withLastSiteData(model("example.com", null));
  expect(warm.siteData).toEqual({ firstPartyCookies: 14, siteCount: 3, thirdPartyPolicy: "allowed" });
  const html = draw(warm);
  expect(html).not.toContain("pageInfo.loading");
  expect(html).toContain("pageInfo.manageSiteData");

  // The host's new read replaces it.
  const fresh = withLastSiteData(
    model("example.com", { firstPartyCookies: 2, siteCount: 1, thirdPartyPolicy: "allowed" }),
  );
  expect(fresh.siteData?.firstPartyCookies).toBe(2);
  expect(withLastSiteData(model("example.com", null)).siteData?.firstPartyCookies).toBe(2);
});

test("another site, a file page or a forgotten site still waits for the host", () => {
  withLastSiteData(model("example.com", { firstPartyCookies: 1, siteCount: 1, thirdPartyPolicy: "allowed" }));
  expect(withLastSiteData(model("other.org", null)).siteData).toBeNull();
  const file = { ...model("/tmp/a.html", null), site: { kind: "file", displayName: "/tmp/a.html" } } as PageInfoModel;
  expect(withLastSiteData(file).siteData).toBeNull();
  forgetSiteData("example.com");
  expect(withLastSiteData(model("example.com", null)).siteData).toBeNull();
});

test("the memory keeps a bounded number of sites", () => {
  for (let i = 0; i < 100; i++)
    withLastSiteData(model(`site${i}.com`, { firstPartyCookies: i, siteCount: 1, thirdPartyPolicy: "allowed" }));
  expect(withLastSiteData(model("site0.com", null)).siteData).toBeNull();
  expect(withLastSiteData(model("site99.com", null)).siteData?.firstPartyCookies).toBe(99);
});
