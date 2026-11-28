// Locator semantics and reads.
await page.goto(`${PRIMARY}/aria.html`);
emit("role-tabs", await page.getByRole("tab").count());
emit("role-tab-selected", await page.getByRole("tab", { selected: true }).textContent());
emit("by-text", await page.getByText("Panel one").count());
emit("by-label", await page.getByLabel("Label for").inputValue());
emit("labelledby", await page.getByRole("textbox", { name: "Labelled by span" }).count());
emit("heading-3", await page.getByRole("heading", { level: 3 }).textContent());
emit("by-title", await page.getByTitle("Title only").count());
emit("nth", await page.locator("button").nth(1).textContent());
emit("first-last", [await page.locator("th").first().textContent(), await page.locator("th").last().textContent()]);
emit("filter", await page.locator("li").filter({ hasText: "main.swift" }).count());
emit("and-or", [await page.getByRole("button").and(page.getByText("Bold")).count(), await page.getByText("Wifi").or(page.getByText("Bold")).count()]);
emit("visible", [await page.getByText("Hidden details text").isVisible(), await page.getByText("Heads up").isVisible()]);
emit("states", [await page.getByRole("switch").isChecked(), await page.locator("#for-input").isEditable(), await page.getByRole("button", { name: "Menu" }).isEnabled()]);
emit("attr", await page.locator("[aria-current]").getAttribute("aria-current"));
emit("all-text", await page.locator("td").allTextContents());
emit("inner-text", await page.locator("[role=alert]").innerText());
emit("eval-all", await page.locator("th").evaluateAll((els) => els.map((e) => e.textContent)));
emit("$$eval", await page.$$eval("td", (els) => els.map((e) => e.textContent)));
emit("evaluate-arg", await page.evaluate((x) => x * 2, 21));
emit("locator-evaluate", await page.locator("h1").evaluate((e, suffix) => e.textContent + suffix, "!"));
emit("count-all", (await page.locator("h2").all()).length);
try {
  await page.locator("button").click({ timeout: 500 });
  emit("strict", "no error");
} catch (e) {
  emit("strict", /strict mode violation/.test(e.message));
}
try {
  await page.locator("#missing").click({ timeout: 300 });
  emit("timeout", "no error");
} catch (e) {
  emit("timeout", e.name);
}
