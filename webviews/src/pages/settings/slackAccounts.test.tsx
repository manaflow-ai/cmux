import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(restore);
const { renderPage, click, settle, ops } = await import("./testing");
const connection = { connected: true, teams: [{ slackTeamId: "T1", name: "Example workspace", cmuxTeamId: "team-1" }] };

test("Accounts connects Slack in the browser and disconnects the returned workspace", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  try {
    const row = () => page.container.querySelector('[data-card="slack-connection"]')!;
    const button = () => row().querySelector("button")!;
    expect(button().textContent).toBe("Connect Slack");
    await click(button());
    expect(ops(page.provider, "cmux.settings.slack.request")).toContainEqual({ method: "POST" });
    expect(ops(page.provider, "cmux.settings.slack.open")).toHaveLength(1);
    page.provider.slack = connection;
    await click(button());
    expect(row().textContent).toContain("Example workspace");
    expect(row().textContent).toContain("Slack connected.");
    expect(button().textContent).toBe("Disconnect");
    await click(button());
    expect(button().textContent).toBe("Connect Slack");
  } finally {
    page.unmount();
  }
});

test("palette route starts the same connection once and consumes its intent", async () => {
  const page = await renderPage({ path: "/settings/accounts?slack=connect&open=unique-invocation" });
  try {
    await settle();
    expect(
      ops(page.provider, "cmux.settings.slack.request").filter(
        (params) => (params as { method: string }).method === "POST",
      ),
    ).toHaveLength(1);
    expect(page.history.location.href).not.toContain("slack=connect");
    expect(page.container.textContent).toContain("Finish connecting in your browser");
  } finally {
    page.unmount();
  }
});

test("OAuth callback reads the server and confirms without trusting the URL's team name", async () => {
  const page = await renderPage({
    path: "/settings/accounts?slack=connected&open=callback&team=Untrusted",
    setup(provider) {
      provider.slack = connection;
    },
  });
  try {
    expect(page.container.textContent).toContain("Example workspace");
    expect(page.container.textContent).toContain("Slack connected.");
    expect(page.container.textContent).not.toContain("Untrusted");
    expect(ops(page.provider, "cmux.settings.slack.open")).toHaveLength(0);
  } finally {
    page.unmount();
  }
});

test("failed connection read shows an actionable error", async () => {
  const page = await renderPage({
    path: "/settings/accounts",
    mock: { failing: { "cmux.settings.slack.request": "slack.unauthorized" } },
  });
  try {
    const row = page.container.querySelector('[data-card="slack-connection"]')!;
    expect(row.querySelector('[role="alert"]')?.textContent).toBe("Sign in to cmux to connect Slack.");
    expect(row.querySelector("button")?.textContent).toBe("Refresh");
  } finally {
    page.unmount();
  }
});
