import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  AGENT_ALLOWED_PARAMS,
  AGENT_PARAM_PATTERNS,
  AGENT_QUERY_PARAMS,
  AGENT_REQUIRED_PARAMS,
  agentLink,
  agentLinkModel,
  agentNativeHref,
} from "../app/[locale]/(landing)/deeplink/[kind]/deeplink-agent";

type SearchParams = Record<string, string | string[] | undefined>;

type Vector = {
  name: string;
  web?: string;
  link?: string | null;
  fields: Record<string, string> | null;
  ignored?: string[];
  missing?: string[];
  invalid?: string[];
};

type Schema = {
  nativeHost: string;
  pathParams: string[];
  queryParams: string[];
  params: Record<string, { required: boolean; pattern: string }>;
  vectors: Vector[];
};

// The one schema the page and the app's parser share; the app runs the same
// vectors, so an emitter and a parser cannot drift.
const SCHEMA_PATH = join(
  import.meta.dir,
  "..",
  "..",
  "schemas",
  "deeplinks",
  "agent-link.json",
);
const schema = JSON.parse(readFileSync(SCHEMA_PATH, "utf8")) as Schema;

/** The search params Next hands a page for `query`: a repeated name is an array. */
function searchParams(query: string): SearchParams {
  const params: SearchParams = {};
  for (const [name, value] of new URLSearchParams(query)) {
    const seen = params[name];
    if (seen === undefined) params[name] = value;
    else if (typeof seen === "string") params[name] = [seen, value];
    else seen.push(value);
  }
  return params;
}

describe("agent deeplink schema", () => {
  test("the page's parameters are the schema's", () => {
    expect([...AGENT_ALLOWED_PARAMS]).toEqual(Object.keys(schema.params));
    expect([...AGENT_REQUIRED_PARAMS]).toEqual(
      Object.entries(schema.params)
        .filter(([, spec]) => spec.required)
        .map(([name]) => name),
    );
    expect([...AGENT_QUERY_PARAMS]).toEqual(schema.queryParams);
    expect([...AGENT_REQUIRED_PARAMS]).toEqual(schema.pathParams);
  });

  test("the page's charsets are the schema's", () => {
    for (const [name, spec] of Object.entries(schema.params)) {
      expect(
        AGENT_PARAM_PATTERNS[name as keyof typeof AGENT_PARAM_PATTERNS].source,
      ).toBe(spec.pattern);
    }
  });

  test.each(
    schema.vectors
      .filter((vector) => vector.web !== undefined)
      .map((vector) => [vector.name, vector] as [string, Vector]),
  )(
    "web vector: %s",
    (_name: string, vector: Vector) => {
      const result = agentLink(searchParams(vector.web ?? ""));
      if (vector.fields === null) {
        expect(result.model).toBeNull();
        expect(vector.link).toBeNull();
        expect(result.missing).toEqual(vector.missing ?? []);
        expect(result.invalid).toEqual(vector.invalid ?? []);
      } else {
        expect(result.model).toEqual({ ...vector.fields, href: vector.link });
        expect(result.missing).toEqual([]);
        expect(result.invalid).toEqual([]);
      }
      expect(result.ignored).toEqual(vector.ignored ?? []);
    },
  );
});

describe("agent deeplink fallback", () => {
  test("builds the path-form native URL cmux NEXT parses", () => {
    expect(
      agentNativeHref({
        harness: "claude",
        session: "abc-123",
        host: "big-red",
        name: "Rivetmoss",
        message: "msg-1",
      }),
    ).toBe(
      "cmux://agent/claude/abc-123?host=big-red&name=Rivetmoss&message=msg-1",
    );
  });

  test("omits absent hints", () => {
    expect(agentNativeHref({ harness: "codex", session: "s.1_x" })).toBe(
      "cmux://agent/codex/s.1_x",
    );
    expect(
      agentNativeHref({ harness: "codex", session: "s1", name: "Lane" }),
    ).toBe("cmux://agent/codex/s1?name=Lane");
  });

  test("accepts valid params", () => {
    const result = agentLink({
      harness: "claude-code",
      session: "a".repeat(200),
      host: "h".repeat(64),
      name: "N.a_m-e",
      message: "m".repeat(200),
    });
    expect(result.ignored).toEqual([]);
    expect(result.invalid).toEqual([]);
    expect(result.model).not.toBeNull();
  });

  test.each<[string, Record<string, string>]>([
    ["harness", { harness: "Claude", session: "s" }],
    ["harness", { harness: "a".repeat(33), session: "s" }],
    ["harness", { harness: "claude/x", session: "s" }],
    ["session", { harness: "claude", session: "a".repeat(201) }],
    ["session", { harness: "claude", session: "../etc" }],
    ["session", { harness: "claude", session: "a b" }],
    ["session", { harness: "claude", session: "<script>" }],
    ["session", { harness: "claude", session: ".." }],
  ])("refuses a link with a bad %s", (param, params) => {
    expect(agentLink(params).invalid).toContain(param);
    expect(agentNativeHref(params)).toBeNull();
  });

  test.each<[string, Record<string, string>]>([
    ["host", { harness: "claude", session: "s", host: "." }],
    ["host", { harness: "claude", session: "s", host: "evil.com/x" }],
    ["host", { harness: "claude", session: "s", host: "h".repeat(65) }],
    ["host", { harness: "claude", session: "s", host: "" }],
    ["name", { harness: "claude", session: "s", name: "two words" }],
    ["name", { harness: "claude", session: "s", name: "n".repeat(65) }],
    ["message", { harness: "claude", session: "s", message: "m".repeat(201) }],
    ["message", { harness: "claude", session: "s", message: "m 1" }],
  ])("ignores a bad %s and still opens the session", (param, params) => {
    const result = agentLink(params);
    expect(result.ignored).toContain(param);
    expect(result.model?.href).toBe("cmux://agent/claude/s");
    const value = params[param];
    if (value !== "") expect(JSON.stringify(result.model)).not.toContain(value);
  });

  test("does not build a native URL without a session", () => {
    expect(agentNativeHref({ harness: "claude" })).toBeNull();
    expect(
      agentNativeHref({ harness: ["claude", "codex"], session: "s" }),
    ).toBeNull();
    expect(agentNativeHref({ harness: "claude", session: "s?x=1#y" })).toBeNull();
  });

  test("model exposes only the URL's fields plus the native href", () => {
    const model = agentLinkModel({
      harness: "claude",
      session: "abc",
      host: "big-red",
      name: "Rivetmoss",
      message: "msg-1",
    });
    expect(model).toEqual({
      harness: "claude",
      session: "abc",
      host: "big-red",
      name: "Rivetmoss",
      message: "msg-1",
      href: "cmux://agent/claude/abc?host=big-red&name=Rivetmoss&message=msg-1",
    });
    expect(
      Object.keys(agentLinkModel({ harness: "claude", session: "abc" }) ?? {}).sort(),
    ).toEqual(["harness", "href", "session"]);
  });

  test.each(["cwd", "account", "token"])(
    "ignores the extra param %s by name and never echoes its value",
    (extra) => {
      const params = { harness: "claude", session: "abc", [extra]: "LEAK" };
      const result = agentLink(params);
      expect(result.ignored).toEqual([extra]);
      expect(result.model?.href).toBe("cmux://agent/claude/abc");
      expect(JSON.stringify(result)).not.toContain("LEAK");
    },
  );

  test("an unknown name is printed inside the charset a name can have", () => {
    const result = agentLink({
      "<img src=x>": "LEAK",
      harness: "claude",
      session: "abc",
    });
    expect(result.ignored).toEqual(["imgsrcx"]);
    expect(result.model).not.toBeNull();
  });

  test("lists at most eight ignored names", () => {
    const params: SearchParams = { harness: "claude", session: "abc" };
    for (let index = 0; index < 20; index += 1) params[`extra-${index}`] = "x";
    expect(agentLink(params).ignored).toHaveLength(8);
  });
});
