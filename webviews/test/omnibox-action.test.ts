// Leo 2026-10-20: the New Tab field has no Search | Ask switch: type and press Return. An address
// or a path opens, a question or an instruction asks the composer's agent, other text searches the
// web. One pure classifier (omniboxAction) decides, and its pick is the suggestions' first row.
import { expect, test } from "bun:test";
import { omniboxAction, type OmniboxAction } from "../src/agent-session/acpmux/omniboxAction";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import { defaultSelection, screenRows } from "../src/agent-session/acpmux/newtab/screenModel";

const home = "/Users/me";
const open = (url: string): OmniboxAction => ({ kind: "open", url });
const ask = (text: string): OmniboxAction => ({ kind: "ask", text });
const search = (text: string): OmniboxAction => ({ kind: "search", text });

const table: [group: string, input: string, action: OmniboxAction][] = [
  // URLs.
  ["url", "https://github.com/manaflow-ai/cmux", open("https://github.com/manaflow-ai/cmux")],
  ["url", "http://example.com/a?b=c", open("http://example.com/a?b=c")],
  ["url", "about:blank", open("about:blank")],
  ["url", "chrome://settings", open("chrome://settings/")],
  // Hosts: a domain with a TLD, localhost and a port, IPs, intranet names.
  ["host", "github.com", open("https://github.com")],
  ["host", "www.google.com", open("https://www.google.com")],
  ["host", "docs.rs/serde", open("https://docs.rs/serde")],
  ["host", "localhost:3000", open("http://localhost:3000")],
  ["host", "127.0.0.1:8080/health", open("http://127.0.0.1:8080/health")],
  ["host", "192.168.1.1", open("http://192.168.1.1")],
  ["host", "8.8.8.8", open("https://8.8.8.8")],
  ["host", "go/gday", open("http://go/gday")],
  ["host", "  github.com  ", open("https://github.com")],
  ["host", "localhost", open("http://localhost")],
  ["host", "localhost:5173", open("http://localhost:5173")],
  ["host", "localhost:3000/api/health", open("http://localhost:3000/api/health")],
  ["host", "0.0.0.0:8000", open("http://0.0.0.0:8000")],
  ["host", "[::1]:3000", open("http://[::1]:3000")],
  ["host", "raspberrypi.local:8080", open("http://raspberrypi.local:8080")],
  // File paths.
  ["path", "/etc/hosts", open("file:///etc/hosts")],
  ["path", "~/Projects", open("file:///Users/me/Projects")],
  ["path", "~", open("file:///Users/me/")],
  ["path", "~/.zshrc", open("file:///Users/me/.zshrc")],
  ["path", "~/Downloads/report.pdf", open("file:///Users/me/Downloads/report.pdf")],
  ["path", "/Users/me/Projects/cmux", open("file:///Users/me/Projects/cmux")],
  ["path", "file:///etc/hosts", open("file:///etc/hosts")],
  // Questions.
  ["question", "what is a monad", ask("what is a monad")],
  ["question", "How do I rebase onto main", ask("How do I rebase onto main")],
  ["question", "why does my build fail", ask("why does my build fail")],
  ["question", "can you check the tests", ask("can you check the tests")],
  ["question", "rust lifetimes?", ask("rust lifetimes?")],
  ["question", "is it safe to delete node_modules", ask("is it safe to delete node_modules")],
  ["question", "What’s new in Swift 6.2", ask("What’s new in Swift 6.2")],
  // Questions without a question mark, as people type them.
  ["question", "how to center a div", ask("how to center a div")],
  ["question", "whats the weather tomorrow", ask("whats the weather tomorrow")],
  ["question", "is rust faster than go", ask("is rust faster than go")],
  ["question", "does bun support workers", ask("does bun support workers")],
  ["question", "can i use structuredClone in safari", ask("can i use structuredClone in safari")],
  ["question", "should i use postgres or sqlite", ask("should i use postgres or sqlite")],
  ["question", "which python", ask("which python")],
  ["question", "who wrote dune", ask("who wrote dune")],
  // Instructions to an agent.
  ["command", "fix the failing login test", ask("fix the failing login test")],
  ["command", "write a haiku about tabs", ask("write a haiku about tabs")],
  ["command", "explain this stack trace", ask("explain this stack trace")],
  ["command", "refactor App.tsx", ask("refactor App.tsx")],
  ["command", "Summarize README.md", ask("Summarize README.md")],
  ["command", "please rename foo", ask("please rename foo")],
  ["command", "can you fix it", ask("can you fix it")],
  ["command", "find the slow query in api", ask("find the slow query in api")],
  ["command", "add a dark mode toggle", ask("add a dark mode toggle")],
  ["command", "run the unit tests", ask("run the unit tests")],
  ["command", "The build is red. Find out why", ask("The build is red. Find out why")],
  [
    "command",
    "open the settings file, then add a font size option",
    ask("open the settings file, then add a font size option"),
  ],
  [
    "command",
    "the sidebar flickers when I drag a tab between two windows quickly",
    ask("the sidebar flickers when I drag a tab between two windows quickly"),
  ],
  ["command", "sketch a name for the app", ask("sketch a name for the app")],
  ["command", "open the voice settings", ask("open the voice settings")],
  ["command", "give me three ideas", ask("give me three ideas")],
  ["command", "use `bun test` here", ask("use `bun test` here")],
  ["command", "line one\nline two", ask("line one\nline two")],
  ["command", "make this faster", ask("make this faster")],
  ["command", "move it up", ask("move it up")],
  ["command", "summarize this page", ask("summarize this page")],
  ["command", "help me write an email", ask("help me write an email")],
  ["command", "run the tests", ask("run the tests")],
  ["command", "tail the logs", ask("tail the logs")],
  ["command", "check the logs", ask("check the logs")],
  ["command", "update the readme", ask("update the readme")],
  // Plain keywords: a web search.
  ["keyword", "weather", search("weather")],
  ["keyword", "rust serde", search("rust serde")],
  ["keyword", "react useEffect cleanup", search("react useEffect cleanup")],
  ["keyword", "fix", search("fix")],
  ["keyword", "explain", search("explain")],
  ["keyword", "test cricket", search("test cricket")],
  ["keyword", "will smith", search("will smith")],
  ["keyword", "design patterns", search("design patterns")],
  ["keyword", "St. Louis weather", search("St. Louis weather")],
  ["keyword", "rust, go", search("rust, go")],
  ["keyword", "node.js", search("node.js")],
  ["keyword", "readme.md", search("readme.md")],
  ["keyword", "go", search("go")],
  ["keyword", "yahoo!", search("yahoo!")],
  ["keyword", "lord of the rings", search("lord of the rings")],
  ["keyword", "the beatles", search("the beatles")],
  ["keyword", "can opener", search("can opener")],
  ["keyword", "find my iphone", search("find my iphone")],
  ["keyword", "build a bear", search("build a bear")],
  ["keyword", "show me love", search("show me love")],
  ["keyword", "update windows 11", search("update windows 11")],
  ["keyword", "delete facebook account", search("delete facebook account")],
  ["keyword", "my chemical romance", search("my chemical romance")],
  ["keyword", "this is us", search("this is us")],
  ["keyword", "review of dune", search("review of dune")],
  ["keyword", "list of presidents", search("list of presidents")],
  ["keyword", "flights to tokyo", search("flights to tokyo")],
  ["keyword", "pizza near me", search("pizza near me")],
  ["keyword", "iphone 17 review", search("iphone 17 review")],
  ["keyword", "python 3.13 release notes", search("python 3.13 release notes")],
  ["keyword", "difference between let and const", search("difference between let and const")],
  ["keyword", "npm install react", search("npm install react")],
  ["keyword", "how", search("how")],
  ["keyword", "shake it off", search("shake it off")],
  ["keyword", "let it be", search("let it be")],
  ["keyword", "kill this love", search("kill this love")],
  ["keyword", "under the tuscan sun", search("under the tuscan sun")],
  ["keyword", "around the world in 80 days", search("around the world in 80 days")],
  ["keyword", "over the garden wall", search("over the garden wall")],
  ["keyword", "the a team movie", search("the a team movie")],
  ["keyword", "tail recursion", search("tail recursion")],
  // Neither.
  ["none", "", { kind: "none" }],
  ["none", "   ", { kind: "none" }],
  ["terminal", "!ls -la", { kind: "terminal", command: "ls -la" }],
];

for (const [group, input, action] of table) {
  test(`${group}: ${JSON.stringify(input)}`, () => {
    expect(omniboxAction(input, { home })).toEqual(action);
  });
}

const agent = { harness: "claude", agent: "Claude Code" };
const lead = (text: string, withAgent = true) => {
  const rows = screenRows(text, { omnibar: EMPTY_OMNIBAR, home, ...(withAgent ? { ask: agent } : {}) });
  return rows[defaultSelection(rows)]?.type;
};

// Leo 2026-10-24 ("Search the web. Do you really want that first?"): the field is a chat
// composer, so Return asks the agent for any text that is not an address, keywords included.
test("the first row, Return's, opens an address and asks for anything else", () => {
  expect(lead("github.com")).toBe("open");
  expect(lead("~/Projects")).toBe("open");
  expect(lead("how do I squash commits")).toBe("ask");
  expect(lead("fix the flaky test")).toBe("ask");
  expect(lead("weather")).toBe("ask");
});

test("Ask stays one row down from an address, and the web search is last", () => {
  const types = (text: string) => screenRows(text, { omnibar: EMPTY_OMNIBAR, ask: agent }).map((row) => row.type);
  expect(types("weather")).toEqual(["ask", "search"]);
  expect(types("why is the sky blue")).toEqual(["ask", "search"]);
  expect(types("github.com")).toEqual(["open", "ask", "search"]);
});

test("a question with no agent to ask searches", () => {
  expect(lead("what is a monad", false)).toBe("search");
});
