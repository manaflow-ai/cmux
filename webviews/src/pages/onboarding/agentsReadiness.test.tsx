// The agents step with the providers' readiness (logins done right): one list, each provider once.
// Claude Code and Codex take their provider's state and one action in place, GitHub is one more row
// of the same list, and without readiness the list is exactly as before.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createStrings } from "../shared/i18n";
import { READINESS, type ReadinessFixture } from "../shared/signIn/galleryFixtures";
import { agentsState } from "./fixtures";
import table from "./generated/strings.json";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";

const strings = createStrings(table, ["en"]);

function render(readiness?: ReadinessFixture): string {
  const store = new OnboardingStore(null, agentsState("mixed"));
  return renderToStaticMarkup(
    <OnboardingPage
      store={store}
      strings={strings}
      readiness={readiness ? { rows: READINESS[readiness], card: { onCopy() {}, onCancel() {} } } : undefined}
    />,
  );
}

const count = (html: string, needle: string) => html.split(needle).length - 1;
const row = (html: string, agent: string) => {
  const start = html.indexOf(`data-agent="${agent}"`);
  const end = html.indexOf("</li>", start);
  return html.slice(start, end);
};

test("one list: each provider once, GitHub as one more row", () => {
  for (const fixture of Object.keys(READINESS) as ReadinessFixture[]) {
    const html = render(fixture);
    expect(count(html, 'class="onb-agent-list"')).toBe(1);
    for (const agent of ["claude", "codex", "gemini", "opencode", "github"])
      expect(count(html, `class="onb-agent" data-agent="${agent}"`)).toBe(1);
    expect(html).not.toContain("signin-ready");
  }
});

test("each row's state and its one action", () => {
  const html = render("mixed");
  expect(row(html, "github")).toContain('data-ready-action="addAccount"');
  expect(row(html, "github")).toContain("Signed in as octocat");
  expect(row(html, "codex")).toContain('data-ready-state="installing"');
  expect(row(html, "codex")).not.toContain("data-ready-action=");
  expect(row(html, "claude")).toContain('data-ready-action="tryAgain"');
  expect(row(html, "claude")).toContain("Try Again");
  // Agents with no provider keep their own rows.
  expect(row(html, "gemini")).toContain('data-trailing="signIn"');
});

test("signing in: the code is in Codex's own row", () => {
  const html = render("signingIn");
  expect(row(html, "codex")).toContain("K7QX-29PF");
  expect(count(html, "K7QX-29PF")).toBe(1);
  expect(row(html, "claude")).toContain('data-ready-action="signIn"');
});

test("without readiness the list is as before", () => {
  const html = render();
  expect(html).not.toContain("data-ready-");
  expect(html).not.toContain('data-agent="github"');
  expect(count(html, 'class="onb-agent"')).toBe(4);
});
