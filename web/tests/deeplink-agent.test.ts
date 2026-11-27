import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
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
  duplicates?: string[];
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
const SCHEMA_URL = new URL(
  "../../schemas/deeplinks/agent-link.json",
  import.meta.url,
);
const schema = JSON.parse(readFileSync(SCHEMA_URL, "utf8")) as Schema;

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

  const webVectors = schema.vectors.filter((vector) => vector.web !== undefined);

  // A renamed or dropped key in the schema would otherwise leave `test.each` with no cases, which
  // bun reports as a green file. Counts alone allow a case to be deleted, so the cases the page
  // answers for are named: adding a vector is free, dropping one of these is not.
  test("the schema carries the page's own vectors", () => {
    const names = webVectors.map((vector) => vector.name);
    expect(new Set(names).size).toBe(names.length);
    expect(names).toEqual(
      expect.arrayContaining([
        "session only",
        "every parameter",
        "a message link, as Leo opened it",
        "an unknown parameter is ignored, the session still opens",
        "an unusable optional value is ignored, the session still opens",
        "a repeated optional parameter is ignored",
        "a machine hint rides along",
        "an unusable machine is ignored, the session still opens",
        "a parameter with nothing in it names nothing, and is said",
        "a repeated required parameter is a repeat, not a session",
        "no session",
        "an unusable session",
        "an unusable harness",
      ]),
    );
    expect(webVectors.filter((vector) => vector.fields === null).length).toBeGreaterThanOrEqual(4);
  });

  test.each(webVectors.map((vector) => [vector.name, vector] as [string, Vector]))(
    "web vector: %s",
    (_name: string, vector: Vector) => {
      const result = agentLink(searchParams(vector.web ?? ""));
      if (vector.fields === null) {
        expect(result.model).toBeNull();
        expect(vector.link).toBeNull();
        expect(result.missing).toEqual(vector.missing ?? []);
        expect(result.invalid).toEqual(vector.invalid ?? []);
        expect(result.duplicates).toEqual(vector.duplicates ?? []);
      } else {
        expect(result.model).toEqual({ ...vector.fields, href: vector.link });
        expect(result.missing).toEqual([]);
        expect(result.invalid).toEqual([]);
        expect(result.duplicates).toEqual([]);
      }
      expect(result.ignored).toEqual(vector.ignored ?? []);
    },
  );
});

describe("agent deeplink fallback", () => {
  test("builds the path-form native URL cmux NEXT parses, in the app's own order", () => {
    expect(
      agentNativeHref({
        harness: "claude",
        session: "abc-123",
        host: "big-red",
        name: "Rivetmoss",
        message: "msg-1",
        machine: "machine_0123456789abcdef0123456789abcdef",
      }),
    ).toBe(
      "cmux://agent/claude/abc-123?host=big-red&name=Rivetmoss&message=msg-1" +
        "&machine=machine_0123456789abcdef0123456789abcdef",
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
      machine: "machine_0123456789abcdef0123456789abcdef",
    });
    expect(result.ignored).toEqual([]);
    expect(result.invalid).toEqual([]);
    expect(result.duplicates).toEqual([]);
    expect(result.model).not.toBeNull();
  });

  test("a required parameter the link carries twice is a repeat, not a bad value", () => {
    for (const params of [
      { harness: "claude", session: ["s1", "s2"] },
      { harness: ["claude", "codex"], session: "s1" },
    ] satisfies SearchParams[]) {
      const result = agentLink(params);
      expect(result.model).toBeNull();
      expect(result.invalid).toEqual([]);
      expect(result.duplicates.length).toBe(1);
      expect(agentNativeHref(params)).toBeNull();
    }
  });

  test("a required parameter with nothing in it is missing, not invalid", () => {
    const result = agentLink({ harness: "claude", session: "" });
    expect(result.missing).toEqual(["session"]);
    expect(result.invalid).toEqual([]);
    expect(result.model).toBeNull();
  });

  test("names the parameters the schema knows before the ones it does not", () => {
    const result = agentLink({
      cwd: "/home/leo",
      harness: "claude",
      session: "s1",
      machine: "nope",
      host: "two words",
      message: "m 1",
      account: "someone@example.com",
    });
    expect(result.ignored).toEqual(["machine", "host", "message", "cwd", "account"]);
    expect(result.model?.href).toBe("cmux://agent/claude/s1");
  });

  test.each<[string, Record<string, string>]>([
    ["harness", { harness: "Claude", session: "s" }],
    ["harness", { harness: "a".repeat(65), session: "s" }],
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
    ["machine", { harness: "claude", session: "s", machine: "nope" }],
    ["machine", { harness: "claude", session: "s", machine: "machine_0123456789ABCDEF0123456789abcdef" }],
    ["machine", { harness: "claude", session: "s", machine: "machine_0123456789abcdef" }],
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

  test("an unknown name that prints as a used parameter is not named", () => {
    const result = agentLink({
      harness: "claude",
      session: "s1",
      host: "big-red",
      "[host]": "x",
      "{name}": "y",
    });
    // `host` is in the link, so saying it was ignored would contradict the link itself; `name` is
    // not, so the sanitised name still earns its warning.
    expect(result.ignored).toEqual(["name"]);
    expect(result.model?.href).toBe("cmux://agent/claude/s1?host=big-red");
  });

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

  test("a printed name is cut to the length a name can have", () => {
    // The cut is what bounds how much of the URL's own text a warning can carry.
    const result = agentLink({ harness: "claude", session: "abc", [`x${"y".repeat(39)}`]: "LEAK" });
    expect(result.ignored).toEqual([`x${"y".repeat(31)}`]);
    expect(result.ignored[0]).toHaveLength(32);
  });

  test("a name with nothing printable left prints as a question mark", () => {
    const result = agentLink({ harness: "claude", session: "abc", "✓": "LEAK" });
    expect(result.ignored).toEqual(["?"]);
    expect(JSON.stringify(result)).not.toContain("LEAK");
  });

  test("a link the page refuses always says which parameter refused it", () => {
    // The page's own fallback wording ("missing required parameters: ") has no names to print, so
    // no refusal may reach it: every refusal names at least one parameter.
    const values: SearchParams[string][] = [undefined, "", "   ", "claude", "s1", "..", ["a", "b"]];
    for (const harness of values) {
      for (const session of values) {
        for (const message of values) {
          const result = agentLink({ harness, session, message });
          if (result.model !== null) continue;
          expect([...result.missing, ...result.invalid, ...result.duplicates].length).toBeGreaterThan(0);
        }
      }
    }
  });
});
