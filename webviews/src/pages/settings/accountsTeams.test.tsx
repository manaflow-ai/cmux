// Settings > Accounts, Teams: each team with your role, its details as an admin and as a member,
// and create, rename and delete as `team.*` gestures (the mock host answers like the app's
// AccountsTeamsModel over the cmux team API).
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, click, fire } = await import("./testing");

type Page = Awaited<ReturnType<typeof renderPage>>;
const group = (page: Page) => page.container.querySelector<HTMLElement>("[data-accounts-team-list]")!;
const team = (page: Page, id: string) => page.container.querySelector<HTMLElement>(`[data-team="${id}"]`);
const teamButton = (scope: ParentNode, id: string) =>
  scope.querySelector<HTMLButtonElement>(`[data-team-button="${id}"]`)!;
const names = (page: Page) =>
  [...group(page).querySelectorAll<HTMLElement>("[data-team] .accounts-team-title")].map(
    (title) => title.firstChild?.textContent,
  );

test("each team shows your role, the active one marked", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  expect(group(page).querySelector(".group-title")?.textContent).toBe("Teams");
  expect(names(page)).toEqual(["Personal", "Acme"]);
  expect(team(page, "team-personal")!.querySelector("[data-team-role]")?.textContent).toBe("Admin");
  expect(team(page, "team-acme")!.querySelector("[data-team-role]")?.textContent).toBe("Member");
  expect(team(page, "team-personal")!.querySelector(".accounts-badge")?.textContent).toBe("Active");
  expect(team(page, "team-acme")!.querySelector(".accounts-badge")).toBeNull();
  page.unmount();
});

test("an unknown role says so", async () => {
  const page = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => (provider.teams.rolesUnknown = true),
  });
  expect(team(page, "team-acme")!.querySelector('[data-team-role="unknown"]')?.textContent).toBe("Role unknown");
  page.unmount();
});

test("an admin's details list members, pending invitations, Rename and Delete", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  const toggle = teamButton(team(page, "team-personal")!, "team.details");
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
  await click(toggle);
  expect(page.provider.accountRuns.at(-1)).toEqual({ action: "team.details", team: "team-personal" });
  const detail = page.container.querySelector<HTMLElement>('[data-team-detail="team-personal"]')!;
  expect(teamButton(team(page, "team-personal")!, "team.details").textContent).toBe("Hide Details");
  expect(detail.querySelector(".accounts-facts")?.textContent).toContain("Your roleAdmin");
  expect(detail.querySelector("[data-team-member]")?.textContent).toContain("You");
  expect(detail.querySelector("[data-team-invitations]")?.textContent).toContain("grace@example.com");
  expect(teamButton(detail, "team.rename")).not.toBeNull();
  expect(teamButton(detail, "team.delete").className).toContain("danger");
  expect(detail.querySelector("[data-team-read-only]")).toBeNull();
  page.unmount();
});

test("a member sees the team read-only, without invitations", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await click(teamButton(team(page, "team-acme")!, "team.details"));
  const detail = page.container.querySelector<HTMLElement>('[data-team-detail="team-acme"]')!;
  expect(detail.querySelectorAll("[data-team-member]").length).toBe(2);
  expect(detail.querySelector("[data-team-invitations]")).toBeNull();
  expect(detail.querySelector('[data-team-button="team.rename"]')).toBeNull();
  expect(detail.querySelector('[data-team-button="team.delete"]')).toBeNull();
  expect(detail.querySelector("[data-team-read-only]")?.textContent).toBe(
    "Only team admins can rename or delete this team.",
  );
  page.unmount();
});

test("rename starts at the current name, refuses a blank one, and renames the team everywhere", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await click(teamButton(team(page, "team-personal")!, "team.details"));
  await click(teamButton(team(page, "team-personal")!, "team.rename"));
  const form = () => team(page, "team-personal")!.querySelector<HTMLElement>('[data-team-form="rename"]')!;
  const field = () => form().querySelector<HTMLInputElement>("input")!;
  expect(field().value).toBe("Personal");
  expect(field().maxLength).toBe(64);
  await changeValue(field(), "   ");
  expect(teamButton(form(), "team.submit").disabled).toBe(true);
  await changeValue(field(), "Research");
  await click(teamButton(form(), "team.submit"));
  expect(page.provider.accountRuns.at(-1)).toEqual({
    action: "team.saveName",
    team: "team-personal",
    name: "Research",
  });
  expect(names(page)).toEqual(["Research", "Acme"]);
  expect(team(page, "team-personal")!.querySelector('[data-team-form="rename"]')).toBeNull();
  expect(group(page).querySelector("[data-team-notice]")?.textContent).toBe("Renamed the team to “Research”.");
  // The Active Team menu shows the new name too.
  expect(page.container.querySelector("[data-accounts-teams] .ui-select-button")?.textContent).toBe("Research");
  page.unmount();
});

test("delete asks first, naming the team; cancel keeps it and confirm moves you to another team", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await click(teamButton(team(page, "team-personal")!, "team.details"));
  await click(teamButton(team(page, "team-personal")!, "team.delete"));
  const confirm = () => page.container.querySelector<HTMLElement>('[data-team-confirm="team-personal"]');
  expect(confirm()?.textContent).toContain("Delete “Personal”?");
  await click(teamButton(confirm()!, "team.cancel"));
  expect(confirm()).toBeNull();
  expect(names(page)).toEqual(["Personal", "Acme"]);

  await click(teamButton(team(page, "team-personal")!, "team.delete"));
  await click(teamButton(confirm()!, "team.confirmDelete"));
  expect(page.provider.accountRuns.at(-1)).toEqual({ action: "team.confirmDelete", team: "team-personal" });
  expect(names(page)).toEqual(["Acme"]);
  expect(team(page, "team-acme")!.querySelector(".accounts-badge")?.textContent).toBe("Active");
  expect(group(page).querySelector("[data-team-notice]")?.textContent).toBe(
    "Deleted “Personal”. “Acme” is now your active team.",
  );
  page.unmount();
});

test("a subscription blocks delete with a clear message and keeps the team", async () => {
  const page = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.teams.teams = provider.teams.teams.map((entry) => ({
        ...entry,
        subscribed: entry.id === "team-personal",
      }));
    },
  });
  await click(teamButton(team(page, "team-personal")!, "team.details"));
  await click(teamButton(team(page, "team-personal")!, "team.delete"));
  const confirm = page.container.querySelector<HTMLElement>('[data-team-confirm="team-personal"]')!;
  await click(teamButton(confirm, "team.confirmDelete"));
  const alert = page.container.querySelector<HTMLElement>('[data-team-confirm="team-personal"] [role="alert"]');
  expect(alert?.textContent).toBe("This team has an active subscription. Cancel it in Billing, then delete the team.");
  expect(names(page)).toEqual(["Personal", "Acme"]);
  page.unmount();
});

test("New Team creates on Return; you become its admin and it becomes the active team", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await click(teamButton(group(page), "team.new"));
  const field = () => group(page).querySelector<HTMLInputElement>('[data-team-form="create"] input')!;
  expect(field().value).toBe("");
  expect(teamButton(group(page).querySelector('[data-team-form="create"]')!, "team.submit").disabled).toBe(true);
  await changeValue(field(), "Design");
  await fire(field(), "keydown", { key: "Enter" });
  await settle();
  expect(page.provider.accountRuns.at(-1)).toEqual({ action: "team.create", name: "Design" });
  expect(names(page)).toEqual(["Personal", "Acme", "Design"]);
  const created = team(page, "team-new-1")!;
  expect(created.querySelector("[data-team-role]")?.textContent).toBe("Admin");
  expect(created.querySelector(".accounts-badge")?.textContent).toBe("Active");
  expect(group(page).querySelector('[data-team-form="create"]')).toBeNull();
  page.unmount();
});

test("Escape closes the New Team form; signed out shows no Teams group", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await click(teamButton(group(page), "team.new"));
  await fire(group(page).querySelector('[data-team-form="create"] input')!, "keydown", { key: "Escape" });
  await settle();
  expect(page.provider.accountRuns.at(-1)).toEqual({ action: "team.cancel" });
  expect(group(page).querySelector('[data-team-form="create"]')).toBeNull();
  page.unmount();
  const signedOut = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = { ...provider.accounts, teams: null };
    },
  });
  expect(signedOut.container.querySelector("[data-accounts-team-list]")).toBeNull();
  signedOut.unmount();
});
