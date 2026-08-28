import { describe, expect, mock, test } from "bun:test";
import posthog from "posthog-js";
import { BrowserDownloadCardAction } from "../app/[locale]/(landing)/browser/browser-download-card-action";
import { PlatformDownloadLink } from "../app/[locale]/components/platform-download-link";

describe("Browser download card action", () => {
  test("tracks enabled landing-page downloads for current and future platforms", () => {
    const originalCapture = posthog.capture;
    const capture = mock(() => undefined);
    posthog.capture = capture as unknown as typeof posthog.capture;

    try {
      const scenarios = [
        {
          platform: "linux",
          artifact: "run-installer",
          href: "/api/download/browser-nightly/linux-x64/run",
        },
        {
          platform: "macos",
          artifact: "dmg",
          href: "/api/download/browser-nightly/mac-arm64/dmg",
        },
      ] as const;

      for (const scenario of scenarios) {
        const action = BrowserDownloadCardAction({
          ...scenario,
          available: true,
          children: `Download for ${scenario.platform}`,
        });

        expect(action.type).toBe(PlatformDownloadLink);
        if (action.type !== PlatformDownloadLink) {
          throw new Error("available download did not render a tracked link");
        }

        const anchor = PlatformDownloadLink(action.props);
        expect(anchor.type).toBe("a");
        expect(anchor.props.href).toBe(scenario.href);
        anchor.props.onClick();
      }

      expect(capture).toHaveBeenCalledTimes(2);
      for (const [index, scenario] of scenarios.entries()) {
        expect(capture).toHaveBeenNthCalledWith(
          index + 1,
          "cmux_browser_download_clicked",
          {
            platform: scenario.platform,
            artifact: scenario.artifact,
            location: "browser-landing",
            target: scenario.href,
          },
          {
            transport: "sendBeacon",
            send_instantly: true,
          },
        );
      }
    } finally {
      posthog.capture = originalCapture;
    }
  });

  test("keeps unavailable landing-page downloads non-interactive", () => {
    const action = BrowserDownloadCardAction({
      platform: "windows",
      artifact: "installer",
      href: "/api/download/browser-nightly/windows-x64/installer",
      available: false,
      children: "Download installer (.exe)",
    });

    expect(action.type).toBe("span");
    expect(action.props["aria-disabled"]).toBe("true");
    expect(action.props.href).toBeUndefined();
    expect(action.props.onClick).toBeUndefined();
  });

  test("wraps long labels inside fixed-width landing-page cards", () => {
    const action = BrowserDownloadCardAction({
      platform: "linux",
      artifact: "run-installer",
      href: "/api/download/browser-nightly/linux-x64/run",
      available: true,
      children: "Download auto-updating installer (.run)",
    });

    if (action.type !== PlatformDownloadLink) {
      throw new Error("enabled download did not render a tracked link");
    }

    const label = action.props.children as {
      type: (props: { children: string }) => {
        type: string;
        props: { className: string; children: string };
      };
      props: { children: string };
    };
    const labelElement = label.type(label.props);
    expect(labelElement.type).toBe("span");
    expect(labelElement.props.className).toContain("min-w-0");
    expect(labelElement.props.className).toContain("whitespace-normal");
    expect(labelElement.props.className).toContain("text-center");
    expect(labelElement.props.children).toBe("Download auto-updating installer (.run)");
  });
});
