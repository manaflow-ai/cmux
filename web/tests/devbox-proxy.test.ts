import { describe, expect, test } from "bun:test";
import { shouldRewriteToDevbox } from "../devbox-routing";

describe("devbox.new host routing", () => {
  test("rewrites the devbox.new homepage to the devbox creator", () => {
    expect(shouldRewriteToDevbox("devbox.new", "/")).toBe(true);
    expect(shouldRewriteToDevbox("www.devbox.new", "/")).toBe(true);
    expect(shouldRewriteToDevbox("devbox.new:443", "/")).toBe(true);
  });

  test("does not rewrite cmux.com or API paths", () => {
    expect(shouldRewriteToDevbox("cmux.com", "/")).toBe(false);
    expect(shouldRewriteToDevbox("devbox.new", "/api/vm")).toBe(false);
    expect(shouldRewriteToDevbox("devbox.new", "/handler/sign-in")).toBe(false);
  });
});
