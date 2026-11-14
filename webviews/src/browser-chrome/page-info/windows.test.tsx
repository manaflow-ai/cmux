import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { CertificateViewer } from "./CertificateViewer";
import { SiteDataWindow, siteDataDetails } from "./SiteDataWindow";
import { SiteSettingsWindow, usageText } from "./SiteSettingsWindow";
import { pageInfoStrings } from "./strings";
import { certificateChain, certificateFailure, noCertificate, siteData, siteSettings } from "./windowFixtures";
import type { PageInfoWindowCommand } from "./windows";

const strings = pageInfoStrings(["en"]);
const ignore = (_: PageInfoWindowCommand) => {};

describe("site settings window", () => {
  test("the usage line counts this site's cookies and the sites with data, or says Loading", () => {
    expect(usageText(strings, { firstPartyCookies: 14, siteCount: 3 })).toBe(
      "Cookies from this site: 14 · Sites with data: 3",
    );
    expect(usageText(strings, null)).toBe("Loading…");
  });

  test("every permission the engine enforces gets a row with its current choice", () => {
    for (const look of ["parity", "grouped", "segmented"] as const) {
      const html = renderToStaticMarkup(
        <SiteSettingsWindow state={siteSettings} onCommand={ignore} look={look} strings={strings} />,
      );
      for (const row of siteSettings.permissions)
        expect(html).toContain(`data-row-id="pageInfo.siteSettings.${row.kind}"`);
      expect(html).toContain("Only the permissions this browser engine can enforce are listed.");
    }
    const segmented = renderToStaticMarkup(
      <SiteSettingsWindow state={siteSettings} onCommand={ignore} look="segmented" strings={strings} />,
    );
    // Pop-ups offer Allow and Block, Block being its default.
    expect(segmented).toContain("Block (default)");
  });

  test("Reset permissions is off while nothing differs from its default", () => {
    const html = renderToStaticMarkup(
      <SiteSettingsWindow state={{ ...siteSettings, canReset: false }} onCommand={ignore} strings={strings} />,
    );
    expect(html).toMatch(/<button[^>]*disabled[^>]*>Reset permissions/);
  });
});

describe("site data window", () => {
  test("a site's details say whose it is, its cookies and other data", () => {
    const [first, cdn, metrics] = siteData.entries!;
    expect(siteDataDetails(strings, first!, true)).toBe("This site · Cookies: 14 · Other site data");
    expect(siteDataDetails(strings, cdn!, true)).toBe("Third party · Cookies: 2");
    expect(siteDataDetails(strings, metrics!, false)).toBe("Other site data");
  });

  test("each site has a delete button named for it; loading and empty say so", () => {
    const html = renderToStaticMarkup(<SiteDataWindow state={siteData} onCommand={ignore} strings={strings} />);
    expect(html).toContain('aria-label="Delete data for cdn-example.net"');
    expect(html).toContain("Done");
    expect(
      renderToStaticMarkup(<SiteDataWindow state={{ entries: null }} onCommand={ignore} strings={strings} />),
    ).toContain("Loading…");
    expect(
      renderToStaticMarkup(<SiteDataWindow state={{ entries: [] }} onCommand={ignore} strings={strings} />),
    ).toContain("No site data");
  });

  test("the grouped look heads this site and third parties", () => {
    const html = renderToStaticMarkup(
      <SiteDataWindow state={siteData} onCommand={ignore} look="grouped" strings={strings} />,
    );
    expect(html.indexOf(">This site<")).toBeLessThan(html.indexOf(">Third party<"));
  });
});

describe("certificate viewer", () => {
  test("the viewer shows both tabs, the leaf's fields and Export", () => {
    const html = renderToStaticMarkup(
      <CertificateViewer state={certificateChain} onCommand={ignore} strings={strings} format={{ timeZone: "UTC" }} />,
    );
    for (const text of ["General", "Details", "Issued To", "meet.example.com", "Certificate Hierarchy", "Export…"])
      expect(html).toContain(text);
  });

  test("a failed verification says why, and an empty chain says there is no certificate", () => {
    expect(
      renderToStaticMarkup(<CertificateViewer state={certificateFailure} onCommand={ignore} strings={strings} />),
    ).toContain("Verification failed: The certificate for this server expired 12 days ago.");
    expect(
      renderToStaticMarkup(<CertificateViewer state={noCertificate} onCommand={ignore} strings={strings} />),
    ).toContain("No certificate is available for this page.");
  });
});
