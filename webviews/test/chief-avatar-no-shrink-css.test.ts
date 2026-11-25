// A Chief's text avatar and an agent's own avatar sit beside a name in flex rows (a received
// message's sender mark, a group head, the hover card, "Sent from <Chief>"). Without `flex: none`
// a long name squeezes the 16px circle into an oval ("An avatar or icon beside text needs
// flex-shrink: 0"). Leo, on the Chief avatars: "i was hoping for the new chief avatars to get in".
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/subagents/AgentCard.css"), "utf8");
const rules = [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector, body]) => ({
  selectors: selector!.split(",").map((part) => part.trim()),
  body: body!.replace(/\s+/g, ""),
}));
const declared = (selector: string, property: string) =>
  rules
    .filter((rule) => rule.selectors.includes(selector))
    .flatMap((rule) => rule.body.split(";").filter((decl) => decl.startsWith(`${property}:`)))
    .map((decl) => decl.slice(property.length + 1));

test.each([".cv-chief-text-avatar", ".cv-agent-avatar"])("%s never shrinks beside long text", (selector) => {
  expect(declared(selector, "flex")).toEqual(["none"]);
});
