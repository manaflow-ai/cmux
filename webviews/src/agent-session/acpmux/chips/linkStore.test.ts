// A link whose site cmux had no icon for is asked again, and a newer answer keeps what an older gave
// (Leo, 2026-11-22: "if the previews dont show up, what's the point? likewise, why do the favicons
// keep turning into globes after stuff?").
import { afterEach, expect, test } from "bun:test";
import { setChipHost } from "./host";
import { askSiteAgain, resetLinkStore, seedLinkStore, SITE_RETRY_MS } from "./linkStore";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

afterEach(() => {
  setChipHost(undefined);
  resetLinkStore();
});

test("a site with no icon is asked again on hover, and the answer keeps its title", async () => {
  const url = "https://example.com/post";
  const asked: string[][] = [];
  let answer: Record<string, unknown> = {};
  setChipHost(async (method, params) => {
    expect(method).toBe("link.inspect");
    asked.push(params.urls as string[]);
    return { sites: answer };
  });
  seedLinkStore({ sites: { [url]: { title: "A post" } } });

  // The tab that opened the site has its icon now.
  answer = { [url]: { icon: "data:image/png;base64,AAAA" } };
  askSiteAgain(url);
  await settle();
  expect(asked).toEqual([[url]]);

  // Once it has an icon it is never asked again.
  askSiteAgain(url);
  await settle();
  expect(asked).toEqual([[url]]);
  expect(SITE_RETRY_MS).toBeGreaterThan(0);
});

test("a hover right after an ask does not ask again", async () => {
  const url = "https://example.org/";
  let calls = 0;
  setChipHost(async () => {
    calls += 1;
    return { sites: {} };
  });
  seedLinkStore({ sites: { [url]: { title: "Example" } } });
  askSiteAgain(url);
  await settle();
  askSiteAgain(url);
  await settle();
  expect(calls).toBe(1);
});

test("a link never seen is not asked by a hover alone", async () => {
  let calls = 0;
  setChipHost(async () => {
    calls += 1;
    return {};
  });
  askSiteAgain("https://never.example/");
  await settle();
  expect(calls).toBe(0);
});
