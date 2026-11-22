// sites.linear: Linear's GraphQL API (schema documented at
// developers.linear.app) called from a background linear.app tab with the
// web session's cookies, the way the Linear web app calls it.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const APP = "https://linear.app";
  const API = "https://client-api.linear.app/graphql";

  async function graphql(arg) {
    // Linear's web client names the signed-in user in a "user" header, from
    // the ApplicationStore it keeps in localStorage.
    const headers = { "content-type": "application/json" };
    try {
      const store = JSON.parse(localStorage.getItem("ApplicationStore") || "null");
      if (store && store.currentUserId) headers.user = store.currentUserId;
    } catch (e) {}
    const r = await fetch(arg.api, { method: "POST", headers, credentials: "include", body: JSON.stringify({ query: arg.query, variables: arg.variables || {}, ...(arg.operationName ? { operationName: arg.operationName } : {}) }) });
    let json = null;
    try {
      json = await r.json();
    } catch (e) {}
    return { status: r.status, json };
  }

  // The operations of a GraphQL document as the GraphQL spec's grammar
  // ("Language") reads them: [{ type, name }] in order, or null when the
  // text is not a well-formed executable document. The lexer skips what
  // GraphQL ignores (whitespace, line terminators, commas, comments, a byte
  // order mark) and reads strings and block strings as single tokens, so
  // keywords and brackets inside them or behind them are read the way the
  // server reads them. Anything it cannot read is null.
  function graphqlOperations(text) {
    const src = String(text);
    const NAME = /[_A-Za-z][_0-9A-Za-z]*/y;
    const NUMBER = /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/y;
    const tokens = [];
    let i = 0;
    while (i < src.length) {
      const c = src[i];
      if (c === " " || c === "\t" || c === "\n" || c === "\r" || c === "," || c === "﻿") {
        i++;
        continue;
      }
      if (c === "#") {
        while (i < src.length && src[i] !== "\n" && src[i] !== "\r") i++;
        continue;
      }
      if (src.startsWith('"""', i)) {
        let j = i + 3;
        for (;;) {
          if (j >= src.length) return null;
          if (src.startsWith('\\"""', j)) j += 4;
          else if (src.startsWith('"""', j)) break;
          else j++;
        }
        tokens.push({ kind: "string" });
        i = j + 3;
        continue;
      }
      if (c === '"') {
        let j = i + 1;
        for (;;) {
          if (j >= src.length || src[j] === "\n" || src[j] === "\r") return null;
          if (src[j] === "\\") j += 2;
          else if (src[j] === '"') break;
          else j++;
        }
        tokens.push({ kind: "string" });
        i = j + 1;
        continue;
      }
      NAME.lastIndex = i;
      const name = NAME.exec(src);
      if (name) {
        tokens.push({ kind: "name", value: name[0] });
        i += name[0].length;
        continue;
      }
      NUMBER.lastIndex = i;
      const number = NUMBER.exec(src);
      if (number && number[0] !== "-") {
        tokens.push({ kind: "number" });
        i += number[0].length;
        continue;
      }
      if (src.startsWith("...", i)) {
        tokens.push({ kind: "punct", value: "..." });
        i += 3;
        continue;
      }
      if ("!$&()[]{}:=@|".includes(c)) {
        tokens.push({ kind: "punct", value: c });
        i++;
        continue;
      }
      return null;
    }

    let p = 0;
    const at = (value) => !!tokens[p] && tokens[p].kind === "punct" && tokens[p].value === value;
    const isName = (value) => !!tokens[p] && tokens[p].kind === "name" && (value === undefined || tokens[p].value === value);
    const CLOSE = { "(": ")", "[": "]", "{": "}" };
    // Skips one balanced (), [] or {} group that starts at tokens[p].
    const group = () => {
      const stack = [];
      do {
        const tk = tokens[p++];
        if (!tk) return false;
        if (tk.kind !== "punct") continue;
        if (CLOSE[tk.value]) stack.push(CLOSE[tk.value]);
        else if (tk.value === ")" || tk.value === "]" || tk.value === "}") {
          if (stack.pop() !== tk.value) return false;
        }
      } while (stack.length);
      return true;
    };
    // Directives (@name, @name(args)), then a selection set.
    const directivesThenSelection = () => {
      while (at("@")) {
        p++;
        if (!isName()) return false;
        p++;
        if (at("(") && !group()) return false;
      }
      return at("{") && group();
    };
    const ops = [];
    while (p < tokens.length) {
      if (at("{")) {
        if (!group()) return null;
        ops.push({ type: "query", name: null });
        continue;
      }
      if (isName("fragment")) {
        p++;
        if (!isName() || isName("on")) return null;
        p++;
        if (!isName("on")) return null;
        p++;
        if (!isName()) return null;
        p++;
        if (!directivesThenSelection()) return null;
        continue;
      }
      if (!isName("query") && !isName("mutation") && !isName("subscription")) return null;
      const type = tokens[p++].value;
      let name = null;
      if (isName()) name = tokens[p++].value;
      if (at("(") && !group()) return null;
      if (!directivesThenSelection()) return null;
      ops.push({ type, name });
    }
    return ops;
  }

  // Why a document is not one read query to run, or null when it is: it
  // must parse, hold only query operations (a mutation or subscription
  // anywhere is refused, whatever operationName selects), and name the
  // one that runs when it holds several.
  function notAReadQuery(text, operationName) {
    const ops = graphqlOperations(text);
    if (!ops || !ops.length) return "is not a GraphQL document this tool can read";
    if (ops.some((o) => o.type !== "query")) return "holds a mutation or subscription";
    if (ops.length > 1 && ops.some((o) => !o.name)) return "mixes an anonymous operation with others";
    if (new Set(ops.map((o) => o.name)).size !== ops.length) return "names two operations alike";
    if (operationName !== undefined && operationName !== null) {
      if (typeof operationName !== "string" || !ops.some((o) => o.name === operationName)) return `has no operation named ${JSON.stringify(operationName)}`;
    } else if (ops.length > 1) return "has several operations; pass { operationName } to pick one";
    return null;
  }

  const ISSUE_FIELDS = "id identifier title url priorityLabel createdAt updatedAt state { name type } assignee { name email } team { key name } labels { nodes { name } }";

  S.register(
    "linear",
    (t) => {
      async function q(query, variables, operationName) {
        const r = await t.inOrigin(APP, graphql, { api: API, query, variables, operationName });
        const errors = (r.json && r.json.errors) || [];
        if (r.status === 401 || errors.some((e) => /auth/i.test((e.extensions && e.extensions.code) || e.message || ""))) throw new S.SiteError("not_signed_in", "linear: the cmux browser is not signed in to Linear; open https://linear.app with tabs.open() and ask the user to sign in");
        if (errors.length) throw new S.SiteError("graphql", `linear: ${errors.map((e) => e.message).join("; ")}`);
        if (!r.json || !r.json.data) throw new S.SiteError("http", `linear: HTTP ${r.status}`);
        return r.json.data;
      }
      const key = (s) => {
        const m = /([A-Z][A-Z0-9]*-\d+)/.exec(String(s || ""));
        if (!m) throw new S.SiteError("invalid", `linear: expected an issue key such as "ENG-123" or an issue URL, got ${JSON.stringify(s)}`);
        return m[1];
      };
      const flat = (i) => ({ ...i, labels: i.labels ? i.labels.nodes.map((l) => l.name) : [] });
      return {
        // { id, name, email, organization }
        async viewer() {
          const d = await q("query { viewer { id name email organization { name urlKey } } }");
          return { id: d.viewer.id, name: d.viewer.name, email: d.viewer.email, organization: d.viewer.organization && d.viewer.organization.name };
        },
        // One issue with its description and comments.
        async issue(input) {
          const d = await q(`query($id: String!) { issue(id: $id) { ${ISSUE_FIELDS} description comments(first: 100) { nodes { body createdAt user { name } } } } }`, { id: key(input) });
          if (!d.issue) throw new S.SiteError("not_found", `linear.issue: ${key(input)} not found`);
          const i = d.issue;
          return { ...flat(i), comments: i.comments.nodes.map((c) => ({ author: c.user && c.user.name, createdAt: c.createdAt, body: c.body })) };
        },
        // Full-text issue search: [{ identifier, title, state, assignee, url, ... }].
        async search(term, options = {}) {
          const d = await q(`query($term: String!, $first: Int) { searchIssues(term: $term, first: $first) { nodes { ${ISSUE_FIELDS} } } }`, { term: String(term), first: options.limit || 25 });
          return d.searchIssues.nodes.map(flat);
        },
        // Issues assigned to the signed-in user, most recently updated first.
        async assigned(options = {}) {
          const d = await q(`query($first: Int) { viewer { assignedIssues(first: $first, orderBy: updatedAt) { nodes { ${ISSUE_FIELDS} } } } }`, { first: options.limit || 25 });
          return d.viewer.assignedIssues.nodes.map(flat);
        },
        // One read-only GraphQL query; options: { operationName } when the
        // document holds several. Mutations go through the Linear UI.
        async query(text, variables, options = {}) {
          const source = String(text);
          const operationName = options && options.operationName !== undefined ? options.operationName : null;
          const why = notAReadQuery(source, operationName);
          if (why) throw new S.SiteError("write_requires_draft", `linear.query: this document ${why}; it runs one read query, and mutations are not run by site tools: make the change in the Linear page`);
          return q(source, variables, operationName);
        },
      };
    },
    { summary: "Linear viewer, issues with comments, search, assigned issues, read-only GraphQL" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
