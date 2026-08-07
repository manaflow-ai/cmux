import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { validInstallEventBody } from "../services/analytics/install";
import CoderouterLandingPage from "../app/coderouter/page";
import { GET as coderouterInstall } from "../app/coderouter/install.sh/route";
import { GET as tuiInstall } from "../app/tui/install.sh/route";
import { GET as tuiPowerShellInstall } from "../app/tui/install.ps1/route";

describe("website install analytics", () => {
  test("renders the clean coderouter curl-install landing page", () => {
    const html = renderToStaticMarkup(<CoderouterLandingPage />);
    const installCommand = [
      "curl -fsSL",
      "https://cmux.com/coderouter/install.sh",
      "| sh",
    ].join(" ");
    expect(html).toContain("keep coding when one account runs out");
    expect(html).toContain(installCommand);
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
