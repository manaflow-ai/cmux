import { expect, test } from "@playwright/test";
import { expectNoErrorCard, watchPage } from "./watch";

const E2E_TEAM_PREFIX = "e2e team ";

// A failed run must not leave teams on the shared account.
test.afterEach(async ({ request, baseURL }) => {
  const catalog = await request.get("/api/subrouter/teams");
  if (!catalog.ok()) return;
  const { teams } = await catalog.json() as { teams: { id: string; name: string }[] };
  for (const team of teams.filter((entry) => entry.name.startsWith(E2E_TEAM_PREFIX))) {
    await request.delete(`/api/teams/${encodeURIComponent(team.id)}`, { headers: { origin: baseURL! } });
  }
});

test("create a team, share an invite link, revoke it, delete the team", async ({ page }) => {
  const watch = watchPage(page);
  const name = `${E2E_TEAM_PREFIX}${Date.now()}`;
  await page.goto("/dashboard/teams");
  await page.getByRole("link", { name: "Create team" }).first().click();
  await expect(page).toHaveURL(/\/dashboard\/teams\/new/);
  await page.getByLabel("Team name").fill(name);
  await page.getByRole("button", { name: "Create team" }).click();

  await expect(page.getByText(`Choose a plan for ${name}`)).toBeVisible();
  await page.getByRole("button", { name: "Continue with Free" }).click();
  await expect(page.getByText(`Invite people to ${name}`)).toBeVisible();
  await page.getByRole("button", { name: "Go to team" }).click();
  await expect(page).toHaveURL(/\/dashboard\/teams\/[^/]+$/);
  await expectNoErrorCard(page);
  const teamUrl = page.url();

  // Regression: with the new team selected, Mac access returned 409.
  await page.locator("aside").getByRole("link", { name: "Mac access", exact: true }).click();
  await expect(page.locator("main").getByRole("heading", { name: /mac access/i }).first()).toBeVisible();
  await expectNoErrorCard(page);
  await page.goto(teamUrl);

  await page.getByRole("link", { name: "Members" }).click();
  await expect(page).toHaveURL(/\/members$/);
  await page.getByRole("button", { name: "Create link" }).click();
  await expect(page.getByText("Copy this link now. It is shown only once.")).toBeVisible();
  await expect(page.locator("text=/\\/join\\/[A-Za-z0-9_-]{20,}/").first()).toBeVisible();
  await page.getByRole("button", { name: "Revoke" }).first().click();
  await page.getByRole("dialog").getByRole("button", { name: /revoke/i }).click();
  await expect(page.getByText("No active invite links.")).toBeVisible();

  await page.getByRole("link", { name: "General" }).click();
  await page.getByRole("button", { name: "Delete team" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("textbox").fill(name);
  await dialog.getByRole("button", { name: /delete/i }).click();
  await expect(page).toHaveURL(/\/dashboard\/teams$/);
  await expect(page.getByText(name)).toHaveCount(0);
  watch.expectClean();
});
