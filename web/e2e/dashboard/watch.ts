import { expect, type Page } from "@playwright/test";

// Dev-only noise that is not a dashboard failure: the shared [locale] layout's
// instant validation, blocked analytics beacons, and Stripe's iframe logs.
const IGNORED_CONSOLE = [
  /Next\.js encountered URL data/,
  /r\.hexclave\.com|r\.cmux\.com/,
  /Failed to load resource: net::ERR_BLOCKED_BY_CLIENT/,
  /stripe/i,
];

/**
 * Records console errors, uncaught exceptions, and failed dashboard API calls
 * so each test can assert the SPA stayed clean end to end.
 */
export function watchPage(page: Page, options: { allowApi?: RegExp[] } = {}) {
  const problems: string[] = [];
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    const text = message.text();
    if (IGNORED_CONSOLE.some((pattern) => pattern.test(text))) return;
    problems.push(`console: ${text.slice(0, 300)}`);
  });
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message.slice(0, 300)}`));
  page.on("response", (response) => {
    const url = response.url();
    if (!url.includes("/api/") || response.status() < 400) return;
    if (options.allowApi?.some((pattern) => pattern.test(url))) return;
    problems.push(`api: ${response.status()} ${response.request().method()} ${url}`);
  });
  return {
    problems,
    expectClean() {
      expect(problems, problems.join("\n")).toEqual([]);
    },
  };
}

/** The screen rendered without an error card or retry prompt. */
export async function expectNoErrorCard(page: Page) {
  await expect(page.getByText(/could not load/i)).toHaveCount(0);
  // Next's route announcer is an empty role=alert outside the page content.
  await expect(page.locator('main [role="alert"]')).toHaveCount(0);
}
