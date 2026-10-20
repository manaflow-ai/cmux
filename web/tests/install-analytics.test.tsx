import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import {
  captureInstallEvent,
  validInstallEventBody,
} from "../services/analytics/install";
import CoderouterLandingPage from "../app/coderouter/page";
import { GET as coderouterInstall } from "../app/coderouter/install.sh/route";
import { GET as tuiInstall } from "../app/tui/install.sh/route";
import { GET as tuiPowerShellInstall } from "../app/tui/install.ps1/route";

describe("website install analytics", () => {
  test("renders the clean coderouter curl-install landing page", () => {
    const html = renderToStaticMarkup(<CoderouterLandingPage />);
    const expectedCommand = [
      "curl -fsSL",
      "https://cmux.com/coderouter/install.sh",
      "| sh",
    ].join(" ");
    expect(html).toContain("keep coding when one account runs out");
    expect(html).toContain(expectedCommand);
    expect(html).toContain("checksum verified");
    expect(html).not.toContain("rounded-");
  });

  test("validates only bounded non-sensitive install dimensions", () => {
    expect(validInstallEventBody({
      product: "coderouter",
      method: "curl",
      platform: "Darwin-arm64",
      version: "0.2.0",
    })).toEqual({
      event: "website_install_succeeded",
      product: "coderouter",
      method: "curl",
      platform: "Darwin-arm64",
      version: "0.2.0",
    });
    expect(validInstallEventBody({
      product: "coderouter",
      method: "curl",
      platform: "x".repeat(65),
    })).toBeNull();
    expect(validInstallEventBody({
      product: "coderouter",
      method: "curl",
      email: "person@example.com",
    })).toEqual({
      event: "website_install_succeeded",
      product: "coderouter",
      method: "curl",
    });
    expect(validInstallEventBody({
      event: "command_copied",
      product: "tui",
      method: "powershell",
    })).toEqual({
      event: "website_install_command_copied",
      product: "tui",
      method: "powershell",
    });
  });

  test("disables GeoIP and persistent person profiles", () => {
    const originalFetch = globalThis.fetch;
    const originalForce = process.env.INSTALL_ANALYTICS_FORCE;
    let captured: Record<string, unknown> | undefined;
    process.env.INSTALL_ANALYTICS_FORCE = "1";
    globalThis.fetch = ((_url: string | URL | Request, init?: RequestInit) => {
      captured = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return Promise.resolve(new Response(null, { status: 200 }));
    }) as typeof fetch;
    try {
      captureInstallEvent({
        event: "website_install_succeeded",
        product: "coderouter",
        method: "curl",
      });
      expect(captured?.distinct_id).toStartWith("anonymous-install:");
      expect(captured?.properties).toMatchObject({
        $geoip_disable: true,
        $process_person_profile: false,
      });
    } finally {
      globalThis.fetch = originalFetch;
      if (originalForce === undefined) {
        delete process.env.INSTALL_ANALYTICS_FORCE;
      } else {
        process.env.INSTALL_ANALYTICS_FORCE = originalForce;
      }
    }
  });

  test("tracks then redirects to immutable static script bodies", () => {
    const coderouter = coderouterInstall(
      new Request("https://cmux.com/coderouter/install.sh"),
    );
    const tui = tuiInstall(new Request("https://cmux.com/tui/install.sh"));
    const tuiPowerShell = tuiPowerShellInstall(
      new Request("https://cmux.com/tui/install.ps1"),
    );
    expect(coderouter.status).toBe(307);
    expect(coderouter.headers.get("location")).toBe(
      "https://cmux.com/coderouter/install-static.sh",
    );
    expect(tui.status).toBe(307);
    expect(tui.headers.get("location")).toBe(
      "https://cmux.com/tui/install-static.sh",
    );
    expect(tuiPowerShell.status).toBe(307);
    expect(tuiPowerShell.headers.get("location")).toBe(
      "https://cmux.com/tui/install-static.ps1",
    );
  });
});
