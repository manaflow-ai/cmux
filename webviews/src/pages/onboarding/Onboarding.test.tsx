import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createStrings } from "../shared/i18n";
import type { AgentsLook } from "./AgentsStep";
import { agentsState, computerUseState, importState } from "./fixtures";
import table from "./generated/strings.json";
import { OnboardingPage } from "./Onboarding";
import { OPS, type OnboardingState } from "./ops";
import { OnboardingStore } from "./store";

const strings = createStrings(table, ["en"]);

function render(state: OnboardingState, look?: AgentsLook): string {
  const store = new OnboardingStore(null, state);
  return renderToStaticMarkup(<OnboardingPage store={store} strings={strings} agentsLook={look} />);
}

/** Text with tags removed, so assertions read what a person reads (hidden sizing labels are attributes). */
const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

describe("agents", () => {
  test("title, line, each agent with its sign-in, and Skip / Continue", () => {
    const html = render(agentsState("mixed"));
    const words = text(html);
    expect(words).toContain("Sign In to Your Agents");
    expect(words).toContain("Sign in to the agent CLIs you use. You can also do this later in Settings.");
    for (const line of ["Signed in", "Not signed in", "Sign-in expired", "Sign-in not checked"])
      expect(words).toContain(line);
    expect(html).toContain('aria-label="Sign In to Codex"');
    expect(words).toContain("Skip");
    expect(words).toContain("Continue");
  });
  test("a signed-in agent keeps the Sign In slot, hidden", () => {
    const html = render(agentsState("mixed"));
    const claude = html.slice(html.indexOf('data-agent="claude"'), html.indexOf('data-agent="codex"'));
    expect(claude).toContain('aria-hidden="true"');
    expect(claude).toContain('tabindex="-1"');
  });
  test("the status line for each state", () => {
    expect(text(render(agentsState("checking")))).toContain("Checking…");
    expect(text(render(agentsState("none")))).toContain("No agent CLIs found on this Mac.");
    expect(text(render(agentsState("signingIn")))).toContain(
      "Finish signing in in the terminal tab, then come back here.",
    );
    expect(text(render(agentsState("failed")))).toContain("Couldn’t open a terminal tab to sign in.");
  });
  test("install offers: Install, the step, the failure and the vendor page", () => {
    const html = render(agentsState("install"));
    const words = text(html);
    expect(words).toContain("Installing… download");
    expect(words).toContain("Failed: npm exited with status 1");
    expect(html).toContain('href="https://example.com/install"');
    expect(html).toContain('data-trailing="install"');
    expect(html).toContain('data-trailing="installing"');
    expect(html).toContain('data-trailing="retry"');
  });
  test("every look draws every row", () => {
    for (const look of ["cards", "list", "compact"] as const) {
      const html = render(agentsState("mixed"), look);
      expect(html).toContain(`data-look="${look}"`);
      expect(html.match(/class="onb-agent"/g)?.length).toBe(4);
    }
  });
});

describe("import", () => {
  test("idle: Find Browsers, no empty rows drawn, not looked for yet", () => {
    const html = render(importState("idle"));
    expect(text(html)).toContain("Import from Browsers");
    expect(text(html)).toContain("Not looked for yet.");
    expect(text(html)).toContain("Find Browsers");
    // The browsers' card keeps its room but draws nothing until a look finds something.
    expect(html.match(/data-state="slot"/g)).toBeNull();
    expect(html).toContain("data-empty");
  });
  test("detecting keeps three icon placeholders and disables the primary", () => {
    const html = render(importState("detecting"));
    expect(html.match(/class="onb-express-icon" data-empty=""/g)?.length).toBe(3);
    expect(text(html)).toContain("Looking for browsers…");
    expect(html).toMatch(/data-primary="detecting"[^>]*disabled/);
  });
  test("ready: one summary with the checked browser and kinds, the grant asks, and the list one click away", () => {
    const html = render(importState("ready"));
    const words = text(html);
    expect(words).toContain("Bring over your browsing from Northwind.");
    expect(words).toContain("Bookmarks · History · Sign-ins");
    expect(words).toContain("Meridian needs Full Disk Access");
    expect(words).toContain("Open System Settings");
    expect(words).toContain("Orbit needs access to its folder");
    expect(words).toContain("Allow Access…");
    expect(words).toContain("Choose Browsers and Data…");
    expect(words).toContain("Import from Another Browser…");
    expect(html).not.toContain("onb-import-row");
  });
  test("importing names the profile being read and sums the counts so far", () => {
    const words = text(render(importState("importing")));
    expect(words).toContain("Importing Northwind · Work…");
    expect(words).toContain("History 8,311");
  });
  test("finished with a failed profile sums it up over the list, whose rows say why", () => {
    const html = render(importState("finished"));
    expect(html).toContain('title="The profile’s history database is locked by the browser."');
    expect(text(html)).toContain(
      "Imported: Bookmarks 204 · History 8,311 · Passwords 41 · Search Engine Passwords skipped: 9 Already saved with a different password: 2. cmux kept the saved password. Some profiles couldn’t be read; hover one for why.",
    );
  });
  test("the folder explainer replaces the list", () => {
    const html = render(importState("accessRefused"));
    expect(html).toContain('data-explainer="access"');
    expect(html).not.toContain('data-state="slot"');
    expect(text(html)).toContain("Allow access to Orbit");
    expect(text(html)).toContain(
      "cmux didn’t get access. Choose ~/Library/Application Support/Orbit in the file picker.",
    );
    expect(text(html)).toContain("Back");
  });
  test("the Keychain explainer and its denied line", () => {
    const html = render(importState("denied"));
    expect(html).toContain('data-explainer="consent"');
    expect(text(html)).toContain("Unlock your data for import");
    expect(text(html)).toContain("“Northwind Safe Storage” and “Meridian Safe Storage”");
    expect(text(html)).toContain("Import Without Passwords");
    expect(text(html)).toContain("Nothing was read");
    expect(text(html)).toContain("Skip Importing");
    expect(text(html)).toContain("Begin Importing");
  });
});

describe("computer use", () => {
  test("fresh: heading, body, both grants, Allow filled on the first", () => {
    const html = render(computerUseState("fresh"));
    expect(text(html)).toContain("Turn On Computer Use");
    expect(text(html)).toContain("Agents can use your apps when you ask them to.");
    expect(html).toContain('aria-label="Allow Accessibility"');
    expect(html).toMatch(/data-variant="solid"[^>]*data-primary-control/);
    expect(text(html)).toContain("Not Now");
  });
  test("all granted: the ready line and Done, no Not Now", () => {
    const words = text(render(computerUseState("allGranted")));
    expect(words).toContain("Computer Use is ready.");
    expect(words).not.toContain("Not Now");
  });
  test("helper failed: the note and Restart", () => {
    const words = text(render(computerUseState("helperFailed")));
    expect(words).toContain("The cmux Computer Use helper did not respond.");
    expect(words).toContain("Restart");
    expect(words).not.toContain("Not Now");
  });
  test("off: the note", () => {
    expect(text(render(computerUseState("off")))).toContain("Computer Use is off.");
  });
});

describe("store", () => {
  test("reads the state, then follows changes; a change before the answer wins", async () => {
    let emit: ((state: OnboardingState) => void) | null = null;
    const calls: string[] = [];
    const store = new OnboardingStore({
      call: async <R,>(op: string): Promise<R> => {
        calls.push(op);
        if (op === OPS.state) {
          emit?.(importState("ready"));
          return agentsState("mixed") as R;
        }
        return {} as R;
      },
      subscribe: async <E,>(_stream: string, onEvent: (data: E, seq: number) => void) => {
        emit = (state) => onEvent(state as E, 1);
        return () => {};
      },
      handle: () => () => {},
    });
    await store.start();
    expect(store.getSnapshot()?.step).toBe("importData");
    store.call(OPS.toggleProfile, { id: "x" });
    expect(calls).toEqual([OPS.state, OPS.toggleProfile]);
  });
});
