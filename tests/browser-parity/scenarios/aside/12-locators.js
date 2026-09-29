// Locator semantics and read APIs.
await openTab(`${PRIMARY}/aria.html`);
emit("role-tabs", await page.getByRole("tab").count());
emit("role-tab-selected", await page.getByRole("tab", { selected: true }).textContent());
emit("by-text", await page.getByText("Panel one").count());
emit("by-label", await page.getByLabel("Label for").inputValue());
emit("labelledby", await page.getByRole("textbox", { name: "Labelled by span" }).count());
emit("heading-3", await page.getByRole("heading", { level: 3 }).textContent());
emit("nth", await page.locator("button").nth(1).textContent());
emit("first-last", [await page.locator("th").first().textContent(), await page.locator("th").last().textContent()]);
emit("filter", await page.locator("li").filter({ hasText: "main.swift" }).count());
emit("visible", [await page.getByText("Hidden details text").isVisible(), await page.getByText("Heads up").isVisible()]);
emit("attr", await page.locator("[aria-current]").getAttribute("aria-current"));
emit("eval-all", await page.locator("th").evaluateAll((els) => els.map((e) => e.textContent)));
emit("$$eval", await page.$$eval("td", (els) => els.map((e) => e.textContent)));
emit("evaluate-arg", await page.evaluate((x) => x * 2, 21));
