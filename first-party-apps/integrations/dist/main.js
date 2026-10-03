// Built by cmux app pack from src/main.ts. Do not edit.
(() => {
  var __defProp = Object.defineProperty;
  var __returnValue = (v) => v;
  function __exportSetter(name, newValue) {
    this[name] = __returnValue.bind(null, newValue);
  }
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: __exportSetter.bind(all, name)
      });
  };
  var exports_main = {};
  __export(exports_main, {
    connect: () => connect3,
    cycleVariant: () => cycleVariant3,
    importApi: () => importApi2,
    openIntegrations: () => openIntegrations2,
    renderPane: () => renderPane,
    renderSection: () => renderSection
  });

  // first-party-apps/integrations/strings/ja.json
  var ja_default = {
    "about.executor": "汎用 API の取り込みは executor (MIT ライセンス、© 2026 Rhys Sullivan) を基にしています。",
    "action.add": "追加",
    "action.addApi": "API を追加",
    "action.addForTeam": "チーム用に追加",
    "action.allow": "許可",
    "action.ask": "確認",
    "action.block": "禁止",
    "action.cancel": "キャンセル",
    "action.connect": "接続",
    "action.connectAnother": "アカウントを追加",
    "action.connectFirst": "アプリを接続",
    "action.disconnect": "接続を解除",
    "action.disconnectConfirm": "接続を解除しますか?",
    "action.makePrivate": "自分専用にする",
    "action.reconnect": "もう一度サインイン",
    "action.shareTeam": "チームと共有",
    "action.tryAgain": "やり直す",
    "add.title": "接続",
    "auth.apiKey": "API キー ({where})",
    "auth.basic": "ユーザー名とパスワード",
    "auth.bearer": "ベアラートークン",
    "auth.headers": "カスタムヘッダー: {names}",
    "auth.oauth": "OAuth でサインイン",
    "auth.oauthClient": "OAuth クライアント資格情報",
    "catalog.filter": "ツールを絞り込む",
    "catalog.help": "許可は確認なしで実行します。確認は毎回あなたの承認が必要です。禁止は実行しません。",
    "catalog.title": "ツール",
    "command.connect.invalid": "provider には次のいずれかを指定してください: {list}",
    "command.import.invalid": "source には仕様の URL または JSON を指定してください",
    "connect.browser": "ブラウザで {provider} を承認してください。",
    "connect.notOpened": "この cmux はまだアプリから {provider} の承認ページを開けません。",
    "detail.account": "アカウント",
    "detail.api": "API",
    "detail.gone": "この接続はもうありません",
    "detail.missing": "接続",
    "detail.repoCount": "{n} 個のリポジトリ",
    "detail.repos": "リポジトリ",
    "detail.scopes": "権限",
    "detail.sharing": "共有",
    "detail.source": "取得元",
    "detail.tools": "ツールとポリシー",
    "error.forbidden": "これを行えるのは接続した本人だけです。",
    "error.missing": "{op} はまだ利用できません。",
    "error.missing.hint": "この画面には、提案中でまだ実装されていないバックエンド操作が必要です。",
    "error.notConfigured": "このプロバイダはこのサーバーでまだ設定されていません。",
    "error.policyDenied": "チームのポリシーで許可されていません。",
    "error.scope": "このアプリは {op} を呼び出せません。",
    "error.signedOut": "連携を表示するには cmux にサインインしてください。",
    "gallery.anyApi": "任意の API",
    "gallery.apps": "アプリ",
    "gallery.blocked": "チームが禁止",
    "gallery.connected": "{n} 件接続済み",
    "gallery.notConfigured": "未設定",
    "health.error": "プロバイダへの直近の呼び出しが失敗しました。",
    "health.expired": "期限内に誰もこの接続を承認しませんでした。",
    "health.reauth": "保存されたサインインをプロバイダが受け付けなくなりました。これを使うエージェントとオートメーションは停止しています。",
    "home.attention": "{n} 件の対応が必要",
    "home.empty": "まだ連携はありません",
    "home.empty.message": "GitHub、Linear、Slack、または任意の API を接続すると、エージェントとオートメーションが使えるようになります。",
    "home.loading": "連携を読み込み中",
    "home.title": "連携",
    "home.yours": "あなたの接続",
    "import.added": "{name} を追加しました。",
    "import.auth": "サインイン",
    "import.defaults": "{total} 個のツール: {allow} 個を許可 (読み取り)、{ask} 個は確認 (変更)、{block} 個を禁止 (破壊的)",
    "import.error.empty": "このドキュメントには操作が定義されていません。",
    "import.error.json": "有効な JSON ではありません。ドキュメント全体か URL を貼り付けてください。",
    "import.error.swagger2": "Swagger 2.0 には対応していません。先に OpenAPI 3 に変換してください。",
    "import.error.unknown": "OpenAPI 3 ドキュメント、GraphQL のイントロスペクション結果、MCP のツール一覧のいずれでもありません。",
    "import.help": "OpenAPI 3 の URL かドキュメント、GraphQL エンドポイントのイントロスペクション結果、または MCP サーバーのツール一覧を貼り付けてください。",
    "import.hint": "仕様の URL、または仕様・イントロスペクション結果・MCP ツール一覧の JSON を貼り付けてください。",
    "import.kindRefused": "このサーバーはまだ {kind} の API を接続できません。",
    "import.loading": "仕様を読み込み中",
    "import.local": "この Mac で読み込みました。追加するときに cmux がもう一度確認します。",
    "import.moreTools": "ほか {n} 個",
    "import.noAuth": "サインイン不要",
    "import.placeholder": "仕様の URL または JSON",
    "import.policyLater": "追加した後で各ツールのポリシーを変更できます。",
    "import.title": "API を追加",
    "import.tools": "ツール",
    "nav.back": "戻る",
    "notice.dismiss": "閉じる",
    "policy.providerBlocked": "チームは {provider} を許可しなくなりました。呼び出しは拒否されます。",
    "policy.sessionOnly": "{op} はまだ利用できません。この変更は cmux を再起動するまで有効です。",
    "policy.source.admin": "チームポリシーは管理者が設定",
    "policy.source.mdm": "チームポリシーはデバイス管理で管理",
    "policy.source.sso": "チームポリシーはシングルサインオンで管理",
    "policy.source.team": "チームポリシーはチーム設定で管理",
    "policy.why.destructive": "既定: 破壊的",
    "policy.why.read": "既定: 読み取り",
    "policy.why.team": "チームが設定",
    "policy.why.user": "あなたのルール",
    "policy.why.write": "既定: データを変更",
    "provider.github.blurb": "Issue、プルリクエスト、リポジトリのイベント",
    "provider.gmail.blurb": "承認のうえでメールの下書きと送信",
    "provider.google_calendar.blurb": "予定の読み取りと招待への返答",
    "provider.graphql.blurb": "イントロスペクションで読み込む任意の GraphQL エンドポイント",
    "provider.linear.blurb": "Issue の作成とチームの更新の追跡",
    "provider.mcp.blurb": "リモート MCP サーバーとそのツール",
    "provider.openapi.blurb": "OpenAPI 3 の記述がある任意の REST API",
    "provider.slack.blurb": "cmux ボットとしてチャンネルに投稿",
    "revoke.done": "{name} の接続を解除しました。",
    "row.subtitle.private": "{provider} · 自分のみ",
    "row.subtitle.team": "{provider} · チームと共有",
    "section.empty": "アプリを接続",
    "section.empty.sub": "GitHub、Linear、Slack、または任意の API",
    "section.pending": "{n} 件が承認待ち",
    "section.summary": "{n} 件接続済み",
    "share.done": "チームと共有しました。",
    "share.private": "あなただけが使えるようになりました。",
    "sharing.private": "自分のみ",
    "sharing.team": "チームと共有",
    "status.active": "接続済み",
    "status.error": "エラー",
    "status.expired": "リンクの期限切れ",
    "status.needsReauth": "サインインが必要",
    "status.pending": "承認待ち",
    "status.pendingShort": "承認待ち",
    "status.revoked": "接続解除",
    "tools.builtin": "組み込みの一覧",
    "tools.counts": "{total} 個のツール · {allow} 個を許可 · {ask} 個は確認 · {block} 個を禁止",
    "tools.counts.one": "1 個のツール · {allow} 個を許可 · {ask} 個は確認 · {block} 個を禁止",
    "tools.loading": "ツールを読み込み中",
    "tools.more": "ほかに {n} 個のツール: 絞り込んで探してください",
    "tools.session": "このセッションで取り込み"
  };
  var tables = { ja: ja_default };
  var language = "en";
  function setLanguage(tag) {
    const base = String(tag ?? "en").toLowerCase().split(/[-_]/)[0] ?? "en";
    language = tables[base] ? base : "en";
  }
  function detectLanguage(ctx) {
    if (ctx && typeof ctx.locale === "string")
      return ctx.locale;
    try {
      const intl = globalThis.Intl;
      if (intl)
        return intl.DateTimeFormat().resolvedOptions().locale;
    } catch {}
    return "en";
  }
  function t(key, english, vars = {}) {
    const template = tables[language]?.[key] ?? english;
    return template.replace(/\{(\w+)\}/g, (whole, name) => (name in vars) ? String(vars[name]) : whole);
  }
  var isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);
  var READ_METHODS = new Set(["get", "head", "options"]);
  var opClassForHttp = (method) => {
    const m = method.toLowerCase();
    if (READ_METHODS.has(m))
      return "read";
    if (m === "delete")
      return "destructive";
    return "mutate-shared";
  };
  var DESTRUCTIVE_VERB = /^(delete|remove|destroy|purge|drop|erase|wipe)(?=[A-Z_]|$)/;
  var opClassForGraphql = (kind, fieldName) => {
    if (kind === "query")
      return "read";
    return DESTRUCTIVE_VERB.test(fieldName) ? "destructive" : "mutate-shared";
  };
  var opClassForMcp = (annotations) => {
    if (annotations?.readOnlyHint === true)
      return "read";
    if (annotations?.destructiveHint === true)
      return "destructive";
    return "mutate-shared";
  };
  var defaultActionFor = (opClass) => {
    switch (opClass) {
      case "read":
      case "mutate-own":
        return "allow";
      case "destructive":
      case "money":
        return "block";
      default:
        return "ask";
    }
  };
  var matchPattern = (pattern, address) => {
    if (pattern === "*")
      return true;
    const patternSegments = pattern.split(".");
    const toolSegments = address.split(".");
    for (let i = 0;i < patternSegments.length; i++) {
      const seg = patternSegments[i];
      if (seg === "*") {
        if (i === patternSegments.length - 1)
          return toolSegments.length >= i;
        if (i >= toolSegments.length)
          return false;
        continue;
      }
      if (i >= toolSegments.length || toolSegments[i] !== seg)
        return false;
    }
    return patternSegments.length === toolSegments.length;
  };
  var patternSpecificity = (pattern) => {
    if (pattern === "*")
      return 0;
    if (pattern.endsWith(".*"))
      return pattern.slice(0, -2).split(".").length * 2;
    return pattern.split(".").length * 2 + 1;
  };
  var restriction = { allow: 1, ask: 2, block: 3 };
  var byPrecedence = (a, b) => patternSpecificity(b.pattern) - patternSpecificity(a.pattern) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  var resolveToolPolicy = (address, rules) => {
    const firstByOwner = new Map;
    for (const rule of [...rules].sort(byPrecedence)) {
      if (firstByOwner.has(rule.owner))
        continue;
      if (matchPattern(rule.pattern, address))
        firstByOwner.set(rule.owner, rule);
    }
    let selected;
    for (const rule of firstByOwner.values()) {
      if (!selected || restriction[rule.action] > restriction[selected.action])
        selected = rule;
    }
    return selected ? { action: selected.action, source: selected.owner, pattern: selected.pattern, ruleId: selected.id } : undefined;
  };
  var resolveEffectivePolicy = (address, rules, defaultAction) => resolveToolPolicy(address, rules) ?? { action: defaultAction, source: "default" };
  var TYPES = new Set(["http", "apiKey", "oauth2", "openIdConnect"]);
  var scopesOf = (v) => isRecord(v) ? Object.keys(v) : [];
  var extractFlows = (rawFlows) => {
    if (!isRecord(rawFlows))
      return;
    const out = {};
    const ac = rawFlows.authorizationCode;
    if (isRecord(ac) && typeof ac.authorizationUrl === "string" && typeof ac.tokenUrl === "string") {
      out.authorizationCode = { authorizationUrl: ac.authorizationUrl, tokenUrl: ac.tokenUrl, scopes: scopesOf(ac.scopes) };
    }
    const cc = rawFlows.clientCredentials;
    if (isRecord(cc) && typeof cc.tokenUrl === "string")
      out.clientCredentials = { tokenUrl: cc.tokenUrl, scopes: scopesOf(cc.scopes) };
    return out.authorizationCode || out.clientCredentials ? out : undefined;
  };
  var extractSecuritySchemes = (raw, resolver) => Object.entries(isRecord(raw) ? raw : {}).flatMap(([name, schemeOrRef]) => {
    const scheme = resolver.resolve(schemeOrRef);
    if (!isRecord(scheme) || typeof scheme.type !== "string" || !TYPES.has(scheme.type))
      return [];
    const type = scheme.type;
    return [
      {
        name,
        type,
        ...typeof scheme.scheme === "string" ? { scheme: scheme.scheme.toLowerCase() } : {},
        ...typeof scheme.in === "string" ? { in: scheme.in } : {},
        ...typeof scheme.name === "string" ? { paramName: scheme.name } : {},
        ...type === "oauth2" ? { flows: extractFlows(scheme.flows) } : {}
      }
    ];
  });
  var buildHeaderMethods = (schemes, strategies) => {
    const byName = new Map(schemes.map((s) => [s.name, s]));
    return strategies.flatMap((strategy) => {
      const resolved = strategy.map((n) => byName.get(n)).filter((s) => !!s);
      if (resolved.length === 0)
        return [];
      const headers = [];
      const query = [];
      const labels = [];
      let kind = "headers";
      for (const scheme of resolved) {
        if (scheme.type === "http" && scheme.scheme === "bearer") {
          headers.push("Authorization");
          labels.push("Bearer token");
          kind = "bearer";
        } else if (scheme.type === "http" && scheme.scheme === "basic") {
          headers.push("Authorization");
          labels.push("Basic auth");
          kind = "basic";
        } else if (scheme.type === "apiKey" && scheme.in === "header") {
          headers.push(scheme.paramName ?? scheme.name);
          labels.push(scheme.name);
          kind = "api_key";
        } else if (scheme.type === "apiKey" && scheme.in === "query") {
          query.push(scheme.paramName ?? scheme.name);
          labels.push(`${scheme.name} (query)`);
          kind = "api_key";
        } else if (scheme.type === "oauth2" || scheme.type === "openIdConnect") {
          return [];
        }
      }
      if (headers.length === 0 && query.length === 0)
        return [];
      const finalKind = headers.length + query.length > 1 ? "headers" : kind;
      return [{ kind: finalKind, label: labels.join(" + "), ...headers.length ? { headers } : {}, ...query.length ? { query } : {} }];
    });
  };
  var buildOAuth2Methods = (schemes) => schemes.flatMap((scheme) => {
    if (scheme.type !== "oauth2" || !scheme.flows)
      return [];
    const out = [];
    const ac = scheme.flows.authorizationCode;
    if (ac)
      out.push({ kind: "oauth2", flow: "authorization_code", label: `OAuth2 · ${scheme.name}`, authorization_url: ac.authorizationUrl, token_url: ac.tokenUrl, scopes: ac.scopes });
    const cc = scheme.flows.clientCredentials;
    if (cc)
      out.push({ kind: "oauth2", flow: "client_credentials", label: `OAuth2 client credentials · ${scheme.name}`, token_url: cc.tokenUrl, scopes: cc.scopes });
    return out;
  });
  var authMethodsFromOpenApi = (doc, resolver) => {
    const components = isRecord(doc.components) ? doc.components : {};
    const schemes = extractSecuritySchemes(components.securitySchemes, resolver);
    const declared = (Array.isArray(doc.security) ? doc.security : []).filter(isRecord).map((entry) => Object.keys(entry));
    const strategies = declared.length > 0 ? declared : schemes.map((s) => [s.name]);
    return [...buildHeaderMethods(schemes, strategies), ...buildOAuth2Methods(schemes)];
  };
  var splitWords = (value) => value.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/([A-Z]+)([A-Z][a-z0-9]+)/g, "$1 $2").replace(/[^a-zA-Z0-9]+/g, " ").trim().split(/\s+/).filter((part) => part.length > 0);
  var toCamelCase = (value) => {
    const words = splitWords(value).map((w) => w.toLowerCase());
    if (words.length === 0)
      return "tool";
    const [first, ...rest] = words;
    return `${first}${rest.map((p) => `${p[0]?.toUpperCase() ?? ""}${p.slice(1)}`).join("")}`;
  };
  var toPascalCase = (value) => {
    const camel = toCamelCase(value);
    return `${camel[0]?.toUpperCase() ?? ""}${camel.slice(1)}`;
  };
  var VERSION_SEGMENT_REGEX = /^v\d+(?:[._-]\d+)?$/i;
  var IGNORED_PATH_SEGMENTS = new Set(["api"]);
  var pathSegmentsFromTemplate = (pathTemplate) => pathTemplate.split("/").map((s) => s.trim()).filter((s) => s.length > 0);
  var isPathParameterSegment = (segment) => segment.startsWith("{") && segment.endsWith("}");
  var normalizeGroupSegment = (value) => {
    const candidate = value?.trim();
    if (!candidate)
      return null;
    return toCamelCase(candidate);
  };
  var deriveVersionSegment = (pathTemplate) => pathSegmentsFromTemplate(pathTemplate).map((s) => s.toLowerCase()).find((s) => VERSION_SEGMENT_REGEX.test(s));
  var derivePathGroup = (pathTemplate) => {
    for (const segment of pathSegmentsFromTemplate(pathTemplate)) {
      const lower = segment.toLowerCase();
      if (VERSION_SEGMENT_REGEX.test(lower))
        continue;
      if (IGNORED_PATH_SEGMENTS.has(lower))
        continue;
      if (isPathParameterSegment(segment))
        continue;
      return normalizeGroupSegment(segment) ?? "root";
    }
    return "root";
  };
  var splitOperationIdSegments = (value) => value.split(/[/.]+/).map((s) => s.trim()).filter((s) => s.length > 0);
  var deriveLeafSeed = (operationId, group) => {
    const segments = splitOperationIdSegments(operationId);
    if (segments.length > 1) {
      const [first, ...rest] = segments;
      if ((normalizeGroupSegment(first) ?? first) === group && rest.length > 0)
        return rest.join(" ");
    }
    return operationId;
  };
  var fallbackLeafSeed = (method, pathTemplate, group) => {
    const relevant = pathSegmentsFromTemplate(pathTemplate).filter((s) => !VERSION_SEGMENT_REGEX.test(s.toLowerCase())).filter((s) => !IGNORED_PATH_SEGMENTS.has(s.toLowerCase())).filter((s) => !isPathParameterSegment(s)).map((s) => normalizeGroupSegment(s) ?? s).filter((s) => s !== group);
    const suffix = relevant.map((s) => toPascalCase(s)).join("");
    return `${method}${suffix || "Operation"}`;
  };
  var deriveLeaf = (operationId, method, pathTemplate, group) => {
    const preferred = toCamelCase(deriveLeafSeed(operationId, group));
    if (preferred.length > 0 && preferred !== group)
      return preferred;
    return toCamelCase(fallbackLeafSeed(method, pathTemplate, group));
  };
  var resolveCollisions = (definitions) => {
    const staged = definitions.map((d) => ({ ...d }));
    const applyFactory = (factory) => {
      const byPath = new Map;
      for (const item of staged) {
        const bucket = byPath.get(item.toolPath) ?? [];
        bucket.push(item);
        byPath.set(item.toolPath, bucket);
      }
      for (const bucket of byPath.values()) {
        if (bucket.length < 2)
          continue;
        for (const d of bucket)
          d.toolPath = factory(d);
      }
    };
    applyFactory((d) => d.versionSegment ? `${d.group}.${d.versionSegment}.${d.leaf}` : d.toolPath);
    const prefix = (d) => d.versionSegment ? `${d.group}.${d.versionSegment}` : d.group;
    applyFactory((d) => `${prefix(d)}.${d.leaf}${toPascalCase(d.method)}`);
    applyFactory((d) => `${prefix(d)}.${d.leaf}${toPascalCase(d.method)}${d.operationHash.slice(0, 8)}`);
    return staged.map((d) => ({ toolPath: d.toolPath, group: d.group, leaf: d.leaf, operationIndex: d.operationIndex }));
  };
  var stableHash = (value) => {
    const str = JSON.stringify(value, Object.keys(value).sort());
    let hash = 0;
    for (let i = 0;i < str.length; i++)
      hash = (hash << 5) - hash + str.charCodeAt(i) | 0;
    return Math.abs(hash).toString(36).padStart(8, "0");
  };
  var planToolPaths = (inputs) => {
    const raw = inputs.map((op, index) => {
      const operationHash = stableHash({ method: op.method, path: op.pathTemplate, operationId: op.operationId });
      const versionSegment = deriveVersionSegment(op.pathTemplate);
      if (op.explicitToolPath) {
        const [group = "root", ...leafParts] = op.explicitToolPath.split(".").filter(Boolean);
        const leaf = leafParts.join(".") || group;
        return { toolPath: op.explicitToolPath, group, leaf, versionSegment, method: op.method, operationHash, operationIndex: index };
      }
      const group = normalizeGroupSegment(op.tag0) ?? derivePathGroup(op.pathTemplate);
      const leaf = deriveLeaf(op.operationId, op.method, op.pathTemplate, group);
      return { toolPath: `${group}.${leaf}`, group, leaf, versionSegment, method: op.method, operationHash, operationIndex: index };
    });
    return resolveCollisions(raw).sort((a, b) => a.toolPath < b.toolPath ? -1 : a.toolPath > b.toolPath ? 1 : 0);
  };
  var HTTP_METHODS = ["get", "put", "post", "delete", "patch", "head", "options", "trace"];
  var VALID_PARAM_LOCATIONS = new Set(["path", "query", "header", "cookie"]);

  class DocResolver {
    doc;
    constructor(doc) {
      this.doc = doc;
    }
    resolve(value) {
      if (isRecord(value) && typeof value.$ref === "string")
        return this.resolvePointer(value.$ref);
      return value ?? null;
    }
    resolvePointer(ref) {
      if (!ref.startsWith("#/"))
        return null;
      let current = this.doc;
      for (const raw of ref.slice(2).split("/")) {
        const segment = raw.replace(/~1/g, "/").replace(/~0/g, "~");
        if (!isRecord(current))
          return null;
        current = current[segment];
      }
      return current;
    }
  }
  var str = (v) => typeof v === "string" ? v : undefined;
  var extractParameters = (pathItem, operation, r) => {
    const merged = new Map;
    for (const raw of [...Array.isArray(pathItem.parameters) ? pathItem.parameters : [], ...Array.isArray(operation.parameters) ? operation.parameters : []]) {
      const p = r.resolve(raw);
      if (!p || typeof p.name !== "string" || typeof p.in !== "string")
        continue;
      merged.set(`${p.in}:${p.name}`, p);
    }
    return [...merged.values()].filter((p) => VALID_PARAM_LOCATIONS.has(p.in)).map((p) => ({
      name: p.name,
      location: p.in,
      required: p.in === "path" ? true : p.required === true,
      ...p.schema !== undefined ? { schema: p.schema } : {},
      ...str(p.description) ? { description: str(p.description) } : {}
    }));
  };
  var extractRequestBody = (operation, r) => {
    if (!operation.requestBody)
      return;
    const body = r.resolve(operation.requestBody);
    if (!body || !isRecord(body.content))
      return;
    const entries = Object.entries(body.content);
    if (entries.length === 0)
      return;
    const [contentType, media] = entries[0];
    return { required: body.required === true, contentType, schema: isRecord(media) ? media.schema : undefined, contentTypes: entries.map(([mt]) => mt) };
  };
  var buildInputSchema = (parameters, body) => {
    const properties = {};
    const required = [];
    for (const param of parameters) {
      properties[param.name] = param.schema ?? { type: "string" };
      if (param.required)
        required.push(param.name);
    }
    if (body) {
      properties.body = body.schema ?? { type: "object" };
      if (body.required)
        required.push("body");
      if (body.contentTypes.length > 1)
        properties.contentType = { type: "string", enum: body.contentTypes, default: body.contentType };
    }
    if (Object.keys(properties).length === 0)
      return;
    return { type: "object", properties, ...required.length > 0 ? { required } : {}, additionalProperties: false };
  };
  var deriveOperationId = (method, pathTemplate, operation) => str(operation.operationId) ?? (`${method}_${pathTemplate.replace(/[^a-zA-Z0-9]+/g, "_")}`.replace(/^_+|_+$/g, "") || `${method}_operation`);
  var explicitToolPath = (operation) => {
    const value = operation["x-cmux-toolPath"];
    return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
  };
  var extractServerList = (servers) => (Array.isArray(servers) ? servers : []).flatMap((server) => {
    if (!isRecord(server) || typeof server.url !== "string")
      return [];
    let url = server.url;
    if (isRecord(server.variables)) {
      for (const [name, v] of Object.entries(server.variables)) {
        if (isRecord(v) && v.default !== undefined)
          url = url.split(`{${name}}`).join(String(v.default));
      }
    }
    return [url];
  });
  var securityScopeAlternatives = (operation, documentSecurity) => {
    const security = operation.security !== undefined ? operation.security : documentSecurity;
    if (!Array.isArray(security) || security.length === 0)
      return;
    const alternatives = [];
    const seen = new Set;
    for (const requirement of security) {
      if (!isRecord(requirement))
        continue;
      const scopes = new Set;
      for (const schemeScopes of Object.values(requirement)) {
        if (!Array.isArray(schemeScopes))
          continue;
        for (const scope of schemeScopes)
          if (typeof scope === "string" && scope.trim().length > 0)
            scopes.add(scope);
      }
      if (scopes.size === 0)
        continue;
      const alternative = [...scopes].sort();
      const key = alternative.join(" ");
      if (seen.has(key))
        continue;
      seen.add(key);
      alternatives.push(alternative);
    }
    return alternatives.length > 0 ? alternatives : undefined;
  };

  class OpenApiExtractionError extends Error {
  }
  var extract = (doc) => {
    if (!isRecord(doc.paths))
      throw new OpenApiExtractionError("OpenAPI document has no paths defined");
    const r = new DocResolver(doc);
    const info = isRecord(doc.info) ? doc.info : {};
    const operations = [];
    const paths = Object.entries(doc.paths).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
    for (const [pathTemplate, rawItem] of paths) {
      const pathItem = r.resolve(rawItem);
      if (!pathItem)
        continue;
      for (const method of HTTP_METHODS) {
        const operation = pathItem[method];
        if (!isRecord(operation))
          continue;
        const parameters = extractParameters(pathItem, operation, r);
        const inputSchema = buildInputSchema(parameters, extractRequestBody(operation, r));
        const scopes = securityScopeAlternatives(operation, doc.security);
        const toolPath = explicitToolPath(operation);
        operations.push({
          operationId: deriveOperationId(method, pathTemplate, operation),
          ...toolPath ? { toolPath } : {},
          method,
          pathTemplate,
          ...str(operation.summary) ? { summary: str(operation.summary) } : {},
          ...str(operation.description) ? { description: str(operation.description) } : {},
          tags: (Array.isArray(operation.tags) ? operation.tags : []).filter((t) => typeof t === "string" && t.trim().length > 0),
          parameters,
          ...inputSchema ? { inputSchema } : {},
          deprecated: operation.deprecated === true,
          ...scopes ? { requiredScopeAlternatives: scopes } : {}
        });
      }
    }
    return { title: str(info.title), description: str(info.description), version: str(info.version), servers: extractServerList(doc.servers), operations };
  };
  var toolsFromOpenApi = (result) => {
    const ops = result.operations;
    const plans = planToolPaths(ops.map((op) => ({ operationId: op.operationId, explicitToolPath: op.toolPath, method: op.method, pathTemplate: op.pathTemplate, tag0: op.tags[0] })));
    return plans.map((plan) => {
      const op = ops[plan.operationIndex];
      const opClass = opClassForHttp(op.method);
      return {
        path: plan.toolPath,
        title: op.summary ?? op.operationId,
        ...op.description ? { description: op.description } : {},
        kind: "openapi",
        method: op.method.toUpperCase(),
        target: op.pathTemplate,
        op_class: opClass,
        default_action: defaultActionFor(opClass),
        ...op.inputSchema ? { input_schema: op.inputSchema } : {},
        ...op.deprecated ? { deprecated: true } : {},
        ...op.requiredScopeAlternatives ? { scopes: op.requiredScopeAlternatives } : {}
      };
    });
  };
  var unwrapTypeName = (ref) => ref.name ? ref.name : ref.ofType ? unwrapTypeName(ref.ofType) : "Unknown";
  var isNonNull = (ref) => ref.kind === "NON_NULL";
  var scalarToJsonSchema = (name) => {
    switch (name) {
      case "String":
      case "ID":
        return { type: "string" };
      case "Int":
        return { type: "integer" };
      case "Float":
        return { type: "number" };
      case "Boolean":
        return { type: "boolean" };
      default:
        return { type: "string", description: `Custom scalar: ${name}` };
    }
  };
  var typeRefToJsonSchema = (ref) => {
    switch (ref.kind) {
      case "NON_NULL":
        return ref.ofType ? typeRefToJsonSchema(ref.ofType) : {};
      case "LIST":
        return { type: "array", items: ref.ofType ? typeRefToJsonSchema(ref.ofType) : {} };
      case "SCALAR":
        return scalarToJsonSchema(ref.name ?? "String");
      case "ENUM":
        return ref.name ? { $ref: `#/$defs/${ref.name}` } : { type: "string" };
      case "INPUT_OBJECT":
        return ref.name ? { $ref: `#/$defs/${ref.name}` } : { type: "object" };
      case "OBJECT":
      case "INTERFACE":
      case "UNION":
        return { type: "object" };
      default:
        return {};
    }
  };
  var buildDefinitions = (types) => {
    const defs = {};
    for (const [name, type] of types) {
      if (name.startsWith("__"))
        continue;
      if (type.kind === "INPUT_OBJECT" && type.inputFields) {
        const properties = {};
        const required = [];
        for (const field of type.inputFields) {
          properties[field.name] = { ...typeRefToJsonSchema(field.type), ...field.description ? { description: field.description } : {} };
          if (isNonNull(field.type))
            required.push(field.name);
        }
        defs[name] = { type: "object", properties, ...required.length ? { required } : {}, ...type.description ? { description: type.description } : {} };
      }
      if (type.kind === "ENUM" && type.enumValues) {
        defs[name] = { type: "string", enum: type.enumValues.map((v) => v.name), ...type.description ? { description: type.description } : {} };
      }
    }
    return defs;
  };
  var buildInputSchema2 = (args) => {
    if (args.length === 0)
      return;
    const properties = {};
    const required = [];
    for (const arg of args) {
      properties[arg.name] = { ...typeRefToJsonSchema(arg.type), ...arg.description ? { description: arg.description } : {} };
      if (isNonNull(arg.type))
        required.push(arg.name);
    }
    return { type: "object", properties, ...required.length ? { required } : {} };
  };
  var formatTypeRef = (ref) => {
    if (ref.kind === "NON_NULL")
      return ref.ofType ? `${formatTypeRef(ref.ofType)}!` : "Unknown!";
    if (ref.kind === "LIST")
      return ref.ofType ? `[${formatTypeRef(ref.ofType)}]` : "[Unknown]";
    return ref.name ?? "Unknown";
  };
  var extractFields = (kind, typeName, types) => {
    const type = typeName ? types.get(typeName) : undefined;
    if (!type?.fields)
      return [];
    return type.fields.filter((f) => !f.name.startsWith("__")).map((field) => {
      const inputSchema = buildInputSchema2(field.args);
      return {
        fieldName: field.name,
        kind,
        ...field.description ? { description: field.description } : {},
        arguments: field.args.map((a) => ({ name: a.name, typeName: formatTypeRef(a.type), required: isNonNull(a.type) })),
        ...inputSchema ? { inputSchema } : {},
        returnTypeName: unwrapTypeName(field.type),
        deprecated: field.isDeprecated === true
      };
    });
  };

  class GraphqlExtractionError extends Error {
  }
  var introspectionSchemaOf = (value) => {
    const root = isRecord(value) && isRecord(value.data) ? value.data : value;
    const schema = isRecord(root) ? root.__schema : undefined;
    return isRecord(schema) && Array.isArray(schema.types) ? schema : null;
  };
  var extract2 = (introspection) => {
    const schema = introspectionSchemaOf(introspection);
    if (!schema)
      throw new GraphqlExtractionError("Not a GraphQL introspection result");
    const typeMap = new Map;
    for (const t of schema.types)
      if (isRecord(t) && typeof t.name === "string")
        typeMap.set(t.name, t);
    return {
      fields: [...extractFields("query", schema.queryType?.name, typeMap), ...extractFields("mutation", schema.mutationType?.name, typeMap)],
      definitions: buildDefinitions(typeMap)
    };
  };
  var toolsFromGraphql = (fields) => fields.map((f) => {
    const opClass = opClassForGraphql(f.kind, f.fieldName);
    return {
      path: `${f.kind}.${f.fieldName}`,
      title: f.fieldName,
      description: f.description ?? `GraphQL ${f.kind}: ${f.fieldName} -> ${f.returnTypeName}`,
      kind: "graphql",
      method: f.kind,
      target: f.fieldName,
      op_class: opClass,
      default_action: defaultActionFor(opClass),
      ...f.inputSchema ? { input_schema: f.inputSchema } : {},
      ...f.deprecated ? { deprecated: true } : {}
    };
  });
  var sanitize = (value) => {
    const s = value.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
    return s || "tool";
  };
  var uniqueId = (value, seen) => {
    const base = sanitize(value);
    const n = (seen.get(base) ?? 0) + 1;
    seen.set(base, n);
    return n === 1 ? base : `${base}_${n}`;
  };
  var BOOL_HINTS = ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"];
  var readAnnotations = (value) => {
    if (!isRecord(value))
      return;
    const out = {};
    if (typeof value.title === "string")
      out.title = value.title;
    for (const key of BOOL_HINTS)
      if (typeof value[key] === "boolean")
        out[key] = value[key];
    return Object.keys(out).length > 0 ? out : undefined;
  };
  var extractManifestFromListToolsResult = (listToolsResult, metadata) => {
    const seen = new Map;
    const listed = isRecord(listToolsResult) && Array.isArray(listToolsResult.tools) ? listToolsResult.tools : [];
    const info = metadata?.serverInfo;
    const server = isRecord(info) ? { name: typeof info.name === "string" ? info.name : null, version: typeof info.version === "string" ? info.version : null } : null;
    const tools = listed.flatMap((tool) => {
      if (!isRecord(tool) || typeof tool.name !== "string")
        return [];
      const toolName = tool.name.trim();
      if (!toolName)
        return [];
      const annotations = readAnnotations(tool.annotations);
      const inputSchema = tool.inputSchema ?? tool.parameters;
      return [
        {
          toolId: uniqueId(toolName, seen),
          toolName,
          description: typeof tool.description === "string" ? tool.description : null,
          ...inputSchema !== undefined ? { inputSchema } : {},
          ...annotations ? { annotations } : {}
        }
      ];
    });
    return { server, tools };
  };
  var slugify = (value) => value.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
  var hostnameOf = (url) => {
    const m = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@/?#]*@)?([^:/?#]+)/i.exec(url.trim());
    return m ? m[1].toLowerCase() : null;
  };
  var deriveMcpNamespace = (input) => {
    if (input.name?.trim())
      return slugify(input.name) || "mcp";
    const host = input.endpoint?.trim() ? hostnameOf(input.endpoint) : null;
    if (host)
      return slugify(host) || "mcp";
    return "mcp";
  };
  var toolsFromMcp = (manifest) => manifest.tools.map((entry) => {
    const opClass = opClassForMcp(entry.annotations);
    return {
      path: entry.toolId,
      title: entry.annotations?.title ?? entry.toolName,
      description: entry.description ?? `MCP tool: ${entry.toolName}`,
      kind: "mcp",
      target: entry.toolName,
      op_class: opClass,
      default_action: defaultActionFor(opClass),
      ...entry.inputSchema !== undefined ? { input_schema: entry.inputSchema } : {}
    };
  });
  class ImportError extends Error {
    code;
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }
  var detectKind = (doc) => {
    if (!isRecord(doc))
      return null;
    if (typeof doc.openapi === "string" && doc.openapi.startsWith("3"))
      return "openapi";
    if (typeof doc.swagger === "string")
      return "swagger2";
    if (introspectionSchemaOf(doc))
      return "graphql";
    const result = isRecord(doc.result) ? doc.result : doc;
    if (Array.isArray(result.tools))
      return "mcp";
    return null;
  };
  var slug = (value) => value.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 40);
  var fnv1a = (text) => {
    let h = 2166136261;
    for (let i = 0;i < text.length; i++) {
      h ^= text.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h.toString(16).padStart(8, "0");
  };
  var catalogDigest = (kind, tools) => `${kind}:${fnv1a(tools.map((t) => `${t.path} ${t.method ?? ""} ${t.target} ${t.op_class}`).join(`
`))}`;
  var importDocument = (doc, options = {}) => {
    const kind = detectKind(doc);
    if (kind === "swagger2")
      throw new ImportError("import.swagger2", "Swagger 2.0 documents are not supported; convert to OpenAPI 3");
    if (!kind)
      throw new ImportError("import.unknown_format", "Not an OpenAPI 3 document, a GraphQL introspection result or an MCP tool list");
    const host = options.sourceUrl ? hostnameOf(options.sourceUrl) : null;
    let catalog;
    if (kind === "openapi") {
      const record = doc;
      const result = extract(record);
      const baseUrl = result.servers[0];
      const title = result.title ?? host ?? "API";
      catalog = {
        kind,
        namespace: slug(result.title ?? "") || slug(host ?? (baseUrl ? hostnameOf(baseUrl) ?? "" : "")) || "api",
        title,
        ...result.version ? { version: result.version } : {},
        ...baseUrl ? { base_url: baseUrl } : {},
        tools: toolsFromOpenApi(result),
        auth: authMethodsFromOpenApi(record, new DocResolver(record))
      };
    } else if (kind === "graphql") {
      const { fields } = extract2(doc);
      catalog = {
        kind,
        namespace: slug(host ?? "") || "graphql",
        title: host ?? "GraphQL API",
        ...options.sourceUrl ? { base_url: options.sourceUrl } : {},
        tools: toolsFromGraphql(fields),
        auth: [{ kind: "bearer", label: "Bearer token", headers: ["Authorization"] }]
      };
    } else {
      const record = doc;
      const manifest = extractManifestFromListToolsResult(isRecord(record.result) ? record.result : record, { serverInfo: options.serverInfo });
      const name = manifest.server?.name ?? null;
      catalog = {
        kind,
        namespace: deriveMcpNamespace({ name, endpoint: options.sourceUrl ?? null }),
        title: name ?? host ?? "MCP server",
        ...manifest.server?.version ? { version: manifest.server.version } : {},
        ...options.sourceUrl ? { base_url: options.sourceUrl } : {},
        tools: toolsFromMcp(manifest),
        auth: [{ kind: "bearer", label: "Bearer token", headers: ["Authorization"] }]
      };
    }
    if (catalog.tools.length === 0)
      throw new ImportError("import.no_tools", "The document declares no operations");
    return { ...catalog, digest: catalogDigest(kind, catalog.tools) };
  };
  var importText = (text, options = {}) => {
    let doc;
    try {
      doc = JSON.parse(text);
    } catch {
      throw new ImportError("import.invalid_json", "The text is not JSON");
    }
    return importDocument(doc, options);
  };
  var defaultCounts = (tools) => {
    const counts = { allow: 0, ask: 0, block: 0 };
    for (const t of tools)
      counts[t.default_action]++;
    return counts;
  };
  var FIRST_CLASS = ["github", "linear", "slack", "google_calendar", "gmail"];
  var GENERIC = ["openapi", "graphql", "mcp"];
  var TABLE = {
    github: { id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", generic: false, ops: [{ op: "github.issue.comment", op_class: "send-external" }] },
    linear: {
      id: "linear",
      name: "Linear",
      symbol: "checklist",
      generic: false,
      ops: [
        { op: "linear.teams.list", op_class: "read" },
        { op: "linear.issue.create", op_class: "mutate-shared" }
      ]
    },
    slack: { id: "slack", name: "Slack", symbol: "number", generic: false, ops: [{ op: "slack.post_as_bot", op_class: "send-external" }] },
    google_calendar: {
      id: "google_calendar",
      name: "Google Calendar",
      symbol: "calendar",
      generic: false,
      ops: [
        { op: "calendar.list", op_class: "read" },
        { op: "calendar.create", op_class: "mutate-shared" },
        { op: "calendar.respond", op_class: "send-external" }
      ]
    },
    gmail: {
      id: "gmail",
      name: "Gmail",
      symbol: "envelope",
      generic: false,
      ops: [
        { op: "mail.draft", op_class: "mutate-own" },
        { op: "mail.send", op_class: "send-external" }
      ]
    },
    openapi: { id: "openapi", name: "OpenAPI", symbol: "curlybraces", generic: true, ops: [] },
    graphql: { id: "graphql", name: "GraphQL", symbol: "point.3.connected.trianglepath.dotted", generic: true, ops: [] },
    mcp: { id: "mcp", name: "MCP", symbol: "server.rack", generic: true, ops: [] }
  };
  var isProviderId = (v) => typeof v === "string" && (v in TABLE);
  var providerInfo = (id) => isProviderId(id) ? TABLE[id] : { id, name: id, symbol: "puzzlepiece.extension", generic: false, ops: [] };
  var providerBlurb = (id) => {
    switch (id) {
      case "github":
        return t("provider.github.blurb", "Issues, pull requests and repository events");
      case "linear":
        return t("provider.linear.blurb", "Create issues and follow team updates");
      case "slack":
        return t("provider.slack.blurb", "Post to channels as the cmux bot");
      case "google_calendar":
        return t("provider.google_calendar.blurb", "Read events and answer invitations");
      case "gmail":
        return t("provider.gmail.blurb", "Draft and send mail with your approval");
      case "openapi":
        return t("provider.openapi.blurb", "Any REST API with an OpenAPI 3 description");
      case "graphql":
        return t("provider.graphql.blurb", "Any GraphQL endpoint, read by introspection");
      case "mcp":
        return t("provider.mcp.blurb", "A remote MCP server and its tools");
      default:
        return "";
    }
  };
  var builtinTools = (id) => providerInfo(id).ops.map((o) => ({
    path: o.op.split(".").slice(1).join("."),
    title: o.op,
    kind: "provider",
    target: o.op,
    op_class: o.op_class,
    default_action: defaultActionFor(o.op_class)
  }));
  var ATTENTION = new Set(["needs_reauth", "error"]);
  var needsAttention = (c) => ATTENTION.has(c.status);
  var isLive = (c) => c.status !== "revoked" && c.status !== "expired";
  var rank = { needs_reauth: 0, error: 1, pending: 2, active: 3, expired: 4, revoked: 5 };
  var cmp = (a, b) => a < b ? -1 : a > b ? 1 : 0;
  var sortConnections = (list) => [...list].filter(isLive).sort((a, b) => rank[a.status] - rank[b.status] || cmp(displayName(a).toLowerCase(), displayName(b).toLowerCase()) || cmp(a.id, b.id));
  var providerOf = (c) => c.catalog?.kind ?? c.provider;
  var displayName = (c) => c.catalog?.title ?? c.account?.name ?? providerInfo(c.provider).name;
  var subtitle = (c) => {
    const provider = providerInfo(providerOf(c)).name;
    return c.sharing === "team" ? t("row.subtitle.team", "{provider} · Shared with team", { provider }) : t("row.subtitle.private", "{provider} · Only you", { provider });
  };
  var statusLabel = (s) => {
    switch (s) {
      case "active":
        return t("status.active", "Connected");
      case "pending":
        return t("status.pending", "Waiting for approval");
      case "needs_reauth":
        return t("status.needsReauth", "Needs sign-in");
      case "error":
        return t("status.error", "Error");
      case "revoked":
        return t("status.revoked", "Disconnected");
      case "expired":
        return t("status.expired", "Link expired");
    }
  };
  var statusTone = (s) => {
    switch (s) {
      case "active":
        return "success";
      case "needs_reauth":
        return "warning";
      case "error":
        return "danger";
      default:
        return "secondary";
    }
  };
  var providerAllowed = (policy, provider) => !policy || policy.allowed_providers === null || policy.allowed_providers.includes(provider);
  var providerConfigured = (list, provider) => !!list?.providers.some((p) => p.provider === provider && p.configured);
  var policySourceLabel = (p) => {
    switch (p.source) {
      case "sso":
        return t("policy.source.sso", "Team policy managed by single sign-on");
      case "mdm":
        return t("policy.source.mdm", "Team policy managed by device management");
      case "team_policy":
        return t("policy.source.team", "Team policy managed by team settings");
      case "admin":
        return t("policy.source.admin", "Team policy set by an admin");
      default:
        return null;
    }
  };
  var counts = (list) => {
    const live = list.filter(isLive);
    return { total: live.length, attention: live.filter(needsAttention).length, pending: live.filter((c) => c.status === "pending").length };
  };
  var [list, setList] = signal(null);
  var [loadProblem, setLoadProblem] = signal(null);
  var [loading, setLoading] = signal(true);
  var [teamPolicy, setTeamPolicy] = signal(null);
  var [route, setRoute] = signal({ screen: "home" });
  var [notice, setNotice] = signal(null);
  var codeOf = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "error";
  var messageOf = (e) => e && typeof e === "object" && ("message" in e) ? String(e.message) : String(e);
  var problemOf = (op, e) => ({ op, code: codeOf(e), message: messageOf(e) });
  var problemText = (p) => {
    switch (p.code) {
      case "operation.unsupported":
        return t("error.missing", "{op} is not available yet.", { op: p.op });
      case "scope.missing":
        return t("error.scope", "This app may not call {op}.", { op: p.op });
      case "auth.unauthenticated":
        return t("error.signedOut", "Sign in to cmux to see your integrations.");
      case "policy.denied":
        return t("error.policyDenied", "Your team's policy does not allow this.");
      case "integration.not_configured":
        return t("error.notConfigured", "This provider is not set up on this server yet.");
      case "auth.forbidden":
        return t("error.forbidden", "Only the person who connected it can do this.");
      default:
        return p.message;
    }
  };
  var isMissing = (p) => !!p && (p.code === "operation.unsupported" || p.code === "scope.missing");
  var say = (text, tone = "secondary") => setNotice({ text, tone });
  var sayProblem = (p) => setNotice({ text: problemText(p), tone: isMissing(p) ? "secondary" : "danger" });
  var generation = 0;
  async function reload() {
    const mine = ++generation;
    const [listResult, policyResult] = await Promise.all([
      cmux.call("integration.list", {}).then((value) => ({ ok: true, value }), (error) => ({ ok: false, error })),
      cmux.call("integration.policy.get", {}).then((value) => value, () => null)
    ]);
    if (mine !== generation)
      return;
    if (listResult.ok) {
      setList(listResult.value);
      setLoadProblem(null);
    } else {
      setLoadProblem(problemOf("integration.list", listResult.error));
    }
    setTeamPolicy(policyResult);
    setLoading(false);
  }
  var connections = computed(() => sortConnections(list()?.connections ?? []));
  var findConnection = (id) => list()?.connections.find((c) => c.id === id) ?? null;
  function applyOwnerRecord(c) {
    const cur = list();
    if (!cur || !c || typeof c.id !== "string" || typeof c.provider !== "string" || typeof c.status !== "string")
      return;
    const rest = cur.connections.filter((x) => x.id !== c.id);
    setList({ ...cur, connections: [...rest, c] });
  }
  var open = (r) => {
    setNotice(null);
    setRoute(r);
  };
  var [confirmingRevoke, setConfirmingRevoke] = signal(null);
  function approvalNotice(r, provider) {
    const name = providerInfo(provider).name;
    if (r.opened === true)
      say(t("connect.browser", "Approve {provider} in your browser.", { provider: name }));
    else
      say(t("connect.notOpened", "This cmux cannot open the {provider} approval page from an app yet.", { provider: name }), "warning");
  }
  async function connect(provider, sharing = "private") {
    try {
      const r = await cmux.call("integration.connect", { provider, sharing });
      applyOwnerRecord(r.connection);
      open({ screen: "detail", id: r.connection.id });
      approvalNotice(r, provider);
    } catch (e) {
      sayProblem(problemOf("integration.connect", e));
    }
  }
  async function reconnect(c) {
    try {
      const r = await cmux.call("integration.reauth", { connection: c.id });
      applyOwnerRecord(r.connection);
      approvalNotice(r, c.provider);
    } catch (e) {
      sayProblem(problemOf("integration.reauth", e));
    }
  }
  async function share(c, sharing) {
    try {
      const r = await cmux.call("integration.share", { connection: c.id, sharing });
      applyOwnerRecord(r);
      say(sharing === "team" ? t("share.done", "Shared with your team.") : t("share.private", "Only you can use it now."), "success");
    } catch (e) {
      sayProblem(problemOf("integration.share", e));
    }
  }
  async function revoke(c) {
    if (confirmingRevoke() !== c.id) {
      setConfirmingRevoke(c.id);
      return;
    }
    setConfirmingRevoke(null);
    try {
      const r = await cmux.call("integration.revoke", { connection: c.id });
      applyOwnerRecord(r);
      open({ screen: "home" });
      say(t("revoke.done", "Disconnected {name}.", { name: c.account?.name ?? providerInfo(c.provider).name }));
    } catch (e) {
      sayProblem(problemOf("integration.revoke", e));
    }
  }
  var cancelRevoke = () => setConfirmingRevoke(null);
  var [byConnection, setByConnection] = signal({});
  var sessionCatalogs = new Map;
  var toolsOf = (id) => byConnection()[id] ?? null;
  var untrackedTools = (id) => untrack(() => toolsOf(id));
  var put = (id, s) => setByConnection({ ...byConnection(), [id]: s });
  var rememberCatalog = (c) => sessionCatalogs.set(c.digest, c);
  var fallback = (c, problem) => {
    const imported = c.catalog ? sessionCatalogs.get(c.catalog.digest) : undefined;
    if (imported)
      return { phase: "ready", namespace: imported.namespace, tools: imported.tools, rules: [], source: "session", problem, catalog: { title: imported.title, ...imported.version ? { version: imported.version } : {}, digest: imported.digest } };
    const builtin = builtinTools(c.provider);
    if (builtin.length > 0)
      return { phase: "ready", namespace: c.provider, tools: builtin, rules: [], source: "builtin", problem };
    return { phase: "error", namespace: c.provider, tools: [], rules: [], source: "builtin", problem };
  };
  async function loadTools(c) {
    const cur = toolsOf(c.id);
    if (!cur)
      put(c.id, { phase: "loading", namespace: c.provider, tools: [], rules: [], source: "gateway" });
    try {
      const v = await cmux.call("integration.tools.list", { connection: c.id });
      put(c.id, { phase: "ready", namespace: v.namespace, tools: v.tools, rules: v.rules, source: "gateway", ...v.catalog ? { catalog: v.catalog } : {} });
    } catch (e) {
      const problem = problemOf("integration.tools.list", e);
      put(c.id, isMissing(problem) ? fallback(c, problem) : { phase: "error", namespace: c.provider, tools: [], rules: [], source: "gateway", problem });
    }
  }
  var addressOf = (s, tool) => `${s.namespace}.${tool.path}`;
  var effectiveOf = (s, tool) => resolveEffectivePolicy(addressOf(s, tool), s.rules, tool.default_action);
  var actionCounts = (s) => {
    const out = { allow: 0, ask: 0, block: 0 };
    for (const tool of s.tools)
      out[effectiveOf(s, tool).action]++;
    return out;
  };
  var withUserRule = (rules, pattern, action) => {
    const rest = rules.filter((r) => !(r.owner === "user" && r.pattern === pattern));
    return action ? [...rest, { id: `local:${pattern}`, owner: "user", pattern, action }] : rest;
  };
  async function setToolAction(c, tool, action) {
    const s = toolsOf(c.id);
    if (!s)
      return;
    const pattern = addressOf(s, tool);
    put(c.id, { ...s, rules: withUserRule(s.rules, pattern, action) });
    try {
      const v = await cmux.call("integration.tools.policy.set", { connection: c.id, owner: "user", pattern, action });
      const now = toolsOf(c.id);
      if (now)
        put(c.id, { ...now, rules: v.rules });
    } catch (e) {
      const p = problemOf("integration.tools.policy.set", e);
      if (isMissing(p)) {
        say(t("policy.sessionOnly", "{op} is not available yet; this change lasts until cmux restarts.", { op: p.op }));
        return;
      }
      const now = toolsOf(c.id);
      if (now)
        put(c.id, { ...now, rules: s.rules });
      sayProblem(p);
    }
  }
  var sourceLabel = (s) => {
    if (s.source === "builtin")
      return t("tools.builtin", "Built-in list");
    if (s.source === "session")
      return t("tools.session", "Imported in this session");
    return null;
  };
  var actionLabel = (a) => a === "allow" ? t("action.allow", "Allow") : a === "ask" ? t("action.ask", "Ask") : t("action.block", "Block");
  var actionTone = (a) => a === "allow" ? "success" : a === "ask" ? "warning" : "danger";
  var [importState, setImportState] = signal({ phase: "idle" });
  var [authIndex, setAuthIndex] = signal(0);
  var importErrorText = (e) => {
    switch (e.code) {
      case "import.invalid_json":
        return t("import.error.json", "That is not valid JSON. Paste the whole document, or a URL.");
      case "import.swagger2":
        return t("import.error.swagger2", "Swagger 2.0 is not supported. Convert it to OpenAPI 3 first.");
      case "import.no_tools":
        return t("import.error.empty", "The document declares no operations.");
      default:
        return t("import.error.unknown", "Not an OpenAPI 3 document, a GraphQL introspection result or an MCP tool list.");
    }
  };
  var URL_RE = /^https?:\/\/\S+$/i;
  var generation2 = 0;
  async function submitImport(text) {
    const value = text.trim();
    const mine = ++generation2;
    setAuthIndex(0);
    if (value === "") {
      setImportState({ phase: "idle" });
      return;
    }
    if (value.startsWith("{")) {
      try {
        const catalog = importText(value);
        setImportState({ phase: "ready", source: { document: value }, catalog, local: true });
      } catch (e) {
        setImportState({ phase: "error", text: e instanceof ImportError ? importErrorText(e) : String(e) });
      }
      return;
    }
    if (!URL_RE.test(value)) {
      setImportState({ phase: "error", text: t("import.hint", "Paste a spec URL, or the JSON of a spec, an introspection result or an MCP tool list.") });
      return;
    }
    const source = { url: value };
    setImportState({ phase: "loading", source });
    try {
      const v = await cmux.call("integration.catalog.preview", { source });
      if (mine === generation2)
        setImportState({ phase: "ready", source, catalog: v.catalog, local: false });
    } catch (e) {
      const p = problemOf("integration.catalog.preview", e);
      if (mine === generation2)
        setImportState({ phase: "error", text: problemText(p), missing: isMissing(p) });
    }
  }
  var resetImport = () => {
    generation2++;
    setImportState({ phase: "idle" });
  };
  var chosenAuth = (catalog) => catalog.auth[authIndex()] ?? catalog.auth[0] ?? null;
  async function addImported(sharing = "private") {
    const s = importState();
    if (s.phase !== "ready")
      return;
    const auth = chosenAuth(s.catalog);
    try {
      const r = await cmux.call("integration.connect", {
        provider: s.catalog.kind,
        source: s.source,
        catalog: { digest: s.catalog.digest, namespace: s.catalog.namespace },
        ...auth ? { auth: { kind: auth.kind, ...auth.headers ? { headers: auth.headers } : {}, ...auth.query ? { query: auth.query } : {}, ...auth.flow ? { flow: auth.flow } : {} } } : {},
        sharing
      });
      rememberCatalog(s.catalog);
      applyOwnerRecord(r.connection);
      resetImport();
      open({ screen: "detail", id: r.connection.id });
      say(t("import.added", "Added {name}.", { name: s.catalog.title }), "success");
    } catch (e) {
      const p = problemOf("integration.connect", e);
      if (p.code === "validation.invalid" || p.code === "invalid_params")
        say(t("import.kindRefused", "This server cannot connect {kind} APIs yet.", { kind: providerInfo(s.catalog.kind).name }), "warning");
      else
        sayProblem(p);
    }
  }
  var VARIANTS = ["connections", "gallery", "catalog"];
  var DEFAULT_VARIANT = "connections";
  var [variantOverride, setVariantOverride] = signal(null);
  var setting = (key) => cmux.app.settings()[key];
  var variant = () => {
    const v = variantOverride() ?? setting("variant");
    return VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  };
  var nextVariant = (v) => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length];
  async function cycleVariant() {
    const next = nextVariant(variant());
    setVariantOverride(next);
    try {
      await cmux.app.settings.set({ variant: next });
      if (setting("variant") === next)
        setVariantOverride(null);
      return { variant: next, persisted: true };
    } catch {
      return { variant: next, persisted: false };
    }
  }
  var invalid = (message) => new CmuxError("invalid_params", message);
  async function openPane() {
    try {
      await cmux.call("app.pane.open", { kind: "pane" });
      return true;
    } catch (e) {
      cmux.log("app.pane.open:", codeOf(e));
      return false;
    }
  }
  async function openIntegrations(args = {}) {
    open(typeof args.connection === "string" && args.connection ? { screen: "detail", id: args.connection } : { screen: "home" });
    await reload();
    return { opened: await openPane() };
  }
  async function connect2(args = {}) {
    const provider = args.provider;
    if (typeof provider !== "string" || !FIRST_CLASS.includes(provider))
      throw invalid(t("command.connect.invalid", "provider must be one of: {list}", { list: FIRST_CLASS.join(", ") }));
    await connect(provider);
    return { opened: await openPane() };
  }
  async function importApi(args = {}) {
    if (typeof args.source !== "string" || !args.source.trim())
      throw invalid(t("command.import.invalid", "source must be a spec URL or JSON"));
    open({ screen: "import" });
    await submitImport(args.source);
    return { opened: await openPane() };
  }
  async function cycleVariant2() {
    return cycleVariant();
  }
  var MAX_ROWS = 5;
  function sectionView(openPane) {
    const attention = () => connections().filter(needsAttention).slice(0, MAX_ROWS);
    const shape = computed(() => loading() ? "loading" : loadProblem() ? "problem" : connections().length === 0 ? "empty" : "list");
    return VStack({ spacing: 0 }, [
      () => {
        switch (shape()) {
          case "loading":
            return null;
          case "problem":
            return Row({ title: () => problemText(loadProblem()), symbol: "puzzlepiece.extension", tint: "secondary" });
          case "empty":
            return Row({ title: t("section.empty", "Connect an app"), subtitle: t("section.empty.sub", "GitHub, Linear, Slack or any API"), symbol: "plus.circle", tint: "secondary" }).onTap(() => openPane());
          default:
            return VStack({ spacing: 0 }, [
              ForEach({ items: attention, key: (c) => c.id }, (c) => Row({ title: () => displayName(c()), subtitle: () => statusLabel(c().status), symbol: () => providerInfo(providerOf(c())).symbol, tint: () => statusTone(c().status) }).onTap(() => openPane(c().id))),
              Row({
                title: () => {
                  const n = counts(connections());
                  return t("section.summary", "{n} connected", { n: n.total - n.attention - n.pending });
                },
                subtitle: () => {
                  const n = counts(connections());
                  return n.pending > 0 ? t("section.pending", "{n} waiting for approval", { n: n.pending }) : null;
                },
                symbol: "puzzlepiece.extension",
                tint: "secondary"
              }).onTap(() => openPane())
            ]);
        }
      }
    ]);
  }
  function header(title, trailing = [], back = false) {
    return HStack({ spacing: 8 }, [
      back ? Icon("chevron.left").color("secondary").onTap(() => open({ screen: "home" })).help(t("nav.back", "Back")) : null,
      Text(title).font("headline").lineLimit(1),
      Spacer(),
      ...trailing
    ]).padding({ top: 10, leading: 12, bottom: 6, trailing: 12 });
  }
  var smallButton = (label, fn) => Button(label, fn).font("caption");
  function noticeLine() {
    return () => {
      const n = notice();
      if (!n)
        return null;
      return HStack({ spacing: 6 }, [
        Text(n.text).font("caption").color(n.tone).lineLimit(3).fixedSize("vertical").layoutPriority(1),
        Spacer(),
        Icon("xmark").font("caption2").color("tertiary").onTap(() => setNotice(null)).help(t("notice.dismiss", "Dismiss"))
      ]).padding({ top: 2, leading: 12, bottom: 6, trailing: 12 });
    };
  }
  var badgeText = (c) => c.status === "pending" ? t("status.pendingShort", "Pending") : statusLabel(c.status);
  var statusBadge = (c) => Badge(badgeText(c), statusTone(c.status)).fixedSize();
  function connectionRow(c, onTap) {
    return HStack({ spacing: 8 }, [
      Icon(() => providerInfo(providerOf(c())).symbol).color(() => needsAttention(c()) ? statusTone(c().status) : "secondary").frame({ width: 18 }),
      VStack({ spacing: 1 }, [Text(() => displayName(c())).lineLimit(1), Text(() => subtitle(c())).font("caption").color("secondary").lineLimit(1)]),
      Spacer(),
      () => c().status === "active" ? null : statusBadge(c())
    ]).padding({ top: 5, leading: 12, bottom: 5, trailing: 12 }).hoverBackground("hover").cursor("pointer").onTap(onTap);
  }
  function policyControl(current, isRule, set) {
    const segment = (a) => Text(actionLabel(a)).font("caption").weight(() => current() === a ? "semibold" : "regular").color(() => current() === a ? actionTone(a) : "tertiary").padding({ top: 2, leading: 6, bottom: 2, trailing: 6 }).background(() => current() === a ? "selected" : null).cornerRadius(4).cursor("pointer").onTap(() => set(current() === a && isRule() ? null : a));
    return HStack({ spacing: 2 }, [segment("allow"), segment("ask"), segment("block")]).padding(1).borderColor("separator").borderWidth(1).cornerRadius(5).fixedSize();
  }
  function problemState(p) {
    return EmptyState({ title: problemText(p), message: isMissing(p) ? t("error.missing.hint", "This screen needs a backend operation that is proposed, not built.") : "", symbol: isMissing(p) ? "puzzlepiece.extension" : "exclamationmark.triangle" });
  }
  var sectionTitle = (text) => Text(text).font("caption").weight("semibold").color("secondary").padding({ top: 10, leading: 12, bottom: 4, trailing: 12 });
  var aboutLine = () => Text(t("about.executor", "Generic API import adapted from executor (MIT License, © 2026 Rhys Sullivan).")).font("caption2").color("tertiary").lineLimit(2).padding({ top: 8, leading: 12, bottom: 10, trailing: 12 });
  var methodBadge = (method) => method ? Text(method.toUpperCase()).font("caption2").monospaced().color("secondary").frame({ width: 52 }) : null;
  var whyLine = (s, tool) => {
    const eff = effectiveOf(s, tool);
    if (eff.source === "team")
      return t("policy.why.team", "Set by your team");
    if (eff.source === "user")
      return t("policy.why.user", "Your rule");
    return tool.op_class === "read" ? t("policy.why.read", "Default: reads") : tool.op_class === "destructive" || tool.op_class === "money" ? t("policy.why.destructive", "Default: destructive") : t("policy.why.write", "Default: changes data");
  };
  function toolRow(c, tool) {
    const state = () => toolsOf(c().id);
    const action = () => {
      const s = state();
      return s ? effectiveOf(s, tool()).action : tool().default_action;
    };
    const isRule = () => {
      const s = state();
      return !!s && effectiveOf(s, tool()).source === "user";
    };
    return HStack({ spacing: 8 }, [
      () => methodBadge(tool().method),
      VStack({ spacing: 1 }, [
        Text(() => tool().title).lineLimit(1).opacity(() => tool().deprecated ? 0.6 : 1),
        Text(() => {
          const s = state();
          return s ? whyLine(s, tool()) : "";
        }).font("caption2").color("tertiary").lineLimit(1)
      ]),
      Spacer(),
      policyControl(action, isRule, (a) => setToolAction(c(), tool(), a))
    ]).padding({ top: 4, leading: 12, bottom: 4, trailing: 12 }).help(() => tool().target);
  }
  var countsLine = (s) => {
    const n = actionCounts(s);
    if (s.tools.length === 1)
      return t("tools.counts.one", "1 tool · {allow} allowed · {ask} ask · {block} blocked", { allow: n.allow, ask: n.ask, block: n.block });
    return t("tools.counts", "{total} tools · {allow} allowed · {ask} ask · {block} blocked", { total: s.tools.length, allow: n.allow, ask: n.ask, block: n.block });
  };
  function toolList(c, query = () => "", limit = 60) {
    const shape = computed(() => {
      const s = toolsOf(c().id);
      return s ? `${s.phase}|${s.source}|${s.problem?.code ?? ""}` : "none";
    });
    const items = () => {
      const q = query().trim().toLowerCase();
      const now = toolsOf(c().id)?.tools ?? [];
      return (q ? now.filter((tool) => `${tool.title} ${tool.path} ${tool.target}`.toLowerCase().includes(q)) : now).slice(0, limit);
    };
    return () => {
      shape();
      const id = untrack(() => c().id);
      const s = untrackedTools(id);
      if (!s || s.phase === "loading")
        return Text(t("tools.loading", "Loading tools")).font("caption").color("secondary").padding({ top: 6, leading: 12, bottom: 6, trailing: 12 });
      if (s.phase === "error" && s.problem)
        return problemState(s.problem);
      const note = sourceLabel(s);
      return VStack({ spacing: 0 }, [
        HStack({ spacing: 6 }, [
          Text(() => {
            const now = toolsOf(c().id);
            return now ? countsLine(now) : "";
          }).font("caption").color("secondary").layoutPriority(1),
          Spacer(),
          note ? Text(note).font("caption2").color("tertiary").lineLimit(1) : null
        ]).padding({ top: 2, leading: 12, bottom: 4, trailing: 12 }),
        ForEach({ items, key: (tool) => tool.path }, (tool) => toolRow(c, tool)),
        () => {
          const n = (toolsOf(c().id)?.tools.length ?? 0) - limit;
          return n > 0 && !query().trim() ? Text(t("tools.more", "{n} more tools: filter to find them", { n })).font("caption").color("tertiary").padding({ top: 4, leading: 12, bottom: 4, trailing: 12 }) : null;
        }
      ]);
    };
  }
  var line = (label, value) => HStack({ spacing: 8 }, [Text(label).font("caption").color("secondary").frame({ width: 92 }), Text(value).font("caption").lineLimit(2), Spacer()]).padding({ top: 2, leading: 12, bottom: 2, trailing: 12 });
  var sharingText = (c) => c.sharing === "team" ? t("sharing.team", "Shared with team") : t("sharing.private", "Only you");
  function healthBlock(c) {
    return () => {
      const conn = c();
      if (!needsAttention(conn) && conn.status !== "expired")
        return null;
      const why = conn.status_detail ?? (conn.status === "needs_reauth" ? t("health.reauth", "The provider no longer accepts the stored sign-in. Agents and automations using it are paused.") : conn.status === "expired" ? t("health.expired", "Nobody approved this connection in time.") : t("health.error", "The last call to the provider failed."));
      return HStack({ spacing: 0 }, [
        VStack({ spacing: 6 }, [
          Text(why).font("caption").color(conn.status === "error" ? "danger" : "warning").lineLimit(4).fixedSize("vertical"),
          conn.capabilities?.reauth === false ? null : smallButton(conn.status === "expired" ? t("action.tryAgain", "Try Again") : t("action.reconnect", "Sign In Again"), () => reconnect(c()))
        ]).padding(10).background("hover").cornerRadius(6)
      ]).padding({ top: 4, leading: 12, bottom: 6, trailing: 12 });
    };
  }
  function actions(c) {
    return () => {
      const conn = c();
      if (conn.status === "revoked")
        return null;
      const arming = confirmingRevoke() === conn.id;
      return HStack({ spacing: 8 }, [
        conn.capabilities?.share === false ? null : conn.sharing === "team" ? smallButton(t("action.makePrivate", "Make Private"), () => share(c(), "private")) : smallButton(t("action.shareTeam", "Share with Team"), () => share(c(), "team")),
        Spacer(),
        arming ? smallButton(t("action.cancel", "Cancel"), cancelRevoke) : null,
        conn.capabilities?.revoke === false ? null : smallButton(arming ? t("action.disconnectConfirm", "Disconnect?") : t("action.disconnect", "Disconnect"), () => revoke(c())).destructive()
      ]).padding({ top: 8, leading: 12, bottom: 4, trailing: 12 });
    };
  }
  function policyNote(c) {
    return () => {
      const p = teamPolicy();
      if (!p)
        return null;
      const conn = c();
      const allowed = providerAllowed(p, conn.provider);
      const source = policySourceLabel(p);
      const text = allowed ? source : t("policy.providerBlocked", "Your team no longer allows {provider}; calls are refused.", { provider: providerInfo(conn.provider).name });
      if (!text)
        return null;
      return Text(text).font("caption").color(allowed ? "tertiary" : "warning").fixedSize("vertical").padding({ top: 2, leading: 12, bottom: 2, trailing: 12 });
    };
  }
  function detailView(id) {
    const c = () => findConnection(id);
    const first = untrack(c);
    if (first)
      loadTools(first);
    const exists = computed(() => !!c());
    return VStack({ spacing: 0 }, [
      () => {
        const present = exists();
        return untrack(() => body(present));
      }
    ]);
    function body(present) {
      if (!present)
        return VStack({ spacing: 0 }, [header(t("detail.missing", "Connection"), [], true), EmptyState({ title: t("detail.gone", "This connection is gone"), symbol: "questionmark.circle" })]);
      const conn = c;
      return VStack({ spacing: 0 }, [
        header(() => displayName(conn()), [], true),
        noticeLine(),
        HStack({ spacing: 8 }, [Icon(() => providerInfo(providerOf(conn())).symbol).color("secondary"), Text(() => providerInfo(providerOf(conn())).name).font("caption").color("secondary"), Spacer(), () => statusBadge(conn())]).padding({ top: 0, leading: 12, bottom: 6, trailing: 12 }),
        healthBlock(conn),
        () => conn().account ? line(t("detail.account", "Account"), () => conn().account?.name ?? "") : null,
        () => conn().catalog ? line(t("detail.api", "API"), () => `${conn().catalog.title}${conn().catalog.version ? ` ${conn().catalog.version}` : ""}`) : null,
        () => conn().catalog?.source_url ? line(t("detail.source", "Source"), () => conn().catalog?.source_url ?? "") : null,
        line(t("detail.sharing", "Sharing"), () => sharingText(conn())),
        () => conn().scopes_granted.length ? line(t("detail.scopes", "Permissions"), () => conn().scopes_granted.join(", ")) : null,
        () => conn().resources?.repos ? line(t("detail.repos", "Repositories"), () => t("detail.repoCount", "{n} repositories", { n: conn().resources?.repos?.length ?? 0 })) : null,
        policyNote(conn),
        actions(conn),
        Divider().padding({ top: 6, leading: 12, bottom: 0, trailing: 12 }),
        sectionTitle(t("detail.tools", "Tools and policy")),
        toolList(conn),
        () => conn().catalog ? aboutLine() : null
      ]);
    }
  }
  var connectedCount = (provider) => (list()?.connections ?? []).filter((c) => c.status === "active" && (c.catalog?.kind ?? c.provider) === provider).length;
  function trailing(provider, generic) {
    return () => {
      if (!providerAllowed(teamPolicy(), provider))
        return Text(t("gallery.blocked", "Blocked by team")).font("caption").color("tertiary");
      if (generic)
        return smallButton(t("action.add", "Add"), () => open({ screen: "import", kind: provider }));
      if (!providerConfigured(list(), provider))
        return Text(t("gallery.notConfigured", "Not set up yet")).font("caption").color("tertiary");
      return smallButton(connectedCount(provider) > 0 ? t("action.connectAnother", "Add Account") : t("action.connect", "Connect"), () => connect(provider));
    };
  }
  function providerCard(provider, generic) {
    const info = providerInfo(provider);
    return HStack({ spacing: 10 }, [
      Icon(info.symbol).font("title3").color("secondary").frame({ width: 26 }),
      VStack({ spacing: 1 }, [
        HStack({ spacing: 6 }, [
          Text(info.name).weight("medium"),
          () => {
            const n = connectedCount(provider);
            return n > 0 ? Badge(t("gallery.connected", "{n} connected", { n }), "success").fixedSize() : null;
          }
        ]),
        Text(providerBlurb(provider)).font("caption").color("secondary").lineLimit(2)
      ]),
      Spacer(),
      trailing(provider, generic)
    ]).padding({ top: 7, leading: 12, bottom: 7, trailing: 12 });
  }
  function gallery() {
    return VStack({ spacing: 0 }, [
      sectionTitle(t("gallery.apps", "Apps")),
      ...FIRST_CLASS.map((p) => providerCard(p, false)),
      sectionTitle(t("gallery.anyApi", "Any API")),
      ...GENERIC.map((k) => providerCard(k, true))
    ]);
  }
  var PREVIEW_TOOLS = 14;
  var authText = (m) => {
    switch (m.kind) {
      case "bearer":
        return t("auth.bearer", "Bearer token");
      case "basic":
        return t("auth.basic", "User name and password");
      case "api_key":
        return t("auth.apiKey", "API key in {where}", { where: [...m.headers ?? [], ...m.query ?? []].join(", ") });
      case "headers":
        return t("auth.headers", "Custom headers: {names}", { names: [...m.headers ?? [], ...m.query ?? []].join(", ") });
      case "oauth2":
        return m.flow === "client_credentials" ? t("auth.oauthClient", "OAuth client credentials") : t("auth.oauth", "Sign in with OAuth");
    }
  };
  function toolPreview(tool) {
    return HStack({ spacing: 8 }, [
      methodBadge(tool.method),
      Text(tool.title).font("caption").lineLimit(1),
      Spacer(),
      Text(actionLabel(tool.default_action)).font("caption2").color(actionTone(tool.default_action))
    ]).padding({ top: 2, leading: 12, bottom: 2, trailing: 12 });
  }
  function authChooser(catalog) {
    if (catalog.auth.length === 0)
      return Text(t("import.noAuth", "No sign-in needed")).font("caption").color("secondary").padding({ top: 2, leading: 12, bottom: 2, trailing: 12 });
    return VStack({ spacing: 0 }, catalog.auth.map((m, i) => HStack({ spacing: 8 }, [
      Icon(() => authIndex() === i ? "largecircle.fill.circle" : "circle").font("caption").color(() => authIndex() === i ? "accent" : "tertiary"),
      Text(authText(m)).font("caption").lineLimit(1),
      Spacer()
    ]).padding({ top: 3, leading: 12, bottom: 3, trailing: 12 }).cursor("pointer").onTap(() => setAuthIndex(i))));
  }
  function previewCard(catalog, local) {
    const n = defaultCounts(catalog.tools);
    const info = providerInfo(catalog.kind);
    return VStack({ spacing: 0 }, [
      HStack({ spacing: 8 }, [
        Icon(info.symbol).color("secondary"),
        VStack({ spacing: 1 }, [
          Text(`${catalog.title}${catalog.version ? ` ${catalog.version}` : ""}`).weight("semibold").lineLimit(1),
          Text(catalog.base_url ? `${info.name} · ${catalog.base_url}` : info.name).font("caption").color("secondary").lineLimit(1)
        ]),
        Spacer()
      ]).padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
      Text(t("import.defaults", "{total} tools: {allow} allowed (reads), {ask} ask first (changes), {block} blocked (destructive)", { total: catalog.tools.length, allow: n.allow, ask: n.ask, block: n.block })).font("caption").color("secondary").lineLimit(2).padding({ top: 2, leading: 12, bottom: 4, trailing: 12 }),
      local ? Text(t("import.local", "Read on this Mac; cmux checks it again when you add it.")).font("caption2").color("tertiary").padding({ top: 0, leading: 12, bottom: 4, trailing: 12 }) : null,
      sectionTitle(t("import.auth", "Sign-in")),
      authChooser(catalog),
      sectionTitle(t("import.tools", "Tools")),
      ...catalog.tools.slice(0, PREVIEW_TOOLS).map(toolPreview),
      catalog.tools.length > PREVIEW_TOOLS ? Text(t("import.moreTools", "and {n} more", { n: catalog.tools.length - PREVIEW_TOOLS })).font("caption").color("tertiary").padding({ top: 2, leading: 12, bottom: 2, trailing: 12 }) : null,
      HStack({ spacing: 8 }, [Spacer(), smallButton(t("action.addForTeam", "Add for Team"), () => addImported("team")), smallButton(t("action.addApi", "Add API"), () => addImported("private"))]).padding({ top: 10, leading: 12, bottom: 4, trailing: 12 }),
      Text(t("import.policyLater", "You can change each tool's policy after adding.")).font("caption2").color("tertiary").padding({ top: 0, leading: 12, bottom: 4, trailing: 12 })
    ]);
  }
  function importView() {
    return VStack({ spacing: 0 }, [
      header(t("import.title", "Add an API"), [], true),
      noticeLine(),
      Text(t("import.help", "Paste an OpenAPI 3 URL or document, a GraphQL endpoint's introspection result, or an MCP server's tool list.")).font("caption").color("secondary").lineLimit(3).padding({ top: 0, leading: 12, bottom: 6, trailing: 12 }),
      TextField("", { placeholder: t("import.placeholder", "Spec URL or JSON"), onSubmit: (text) => submitImport(text) }).padding({ top: 0, leading: 12, bottom: 6, trailing: 12 }),
      () => {
        const s = importState();
        switch (s.phase) {
          case "idle":
            return null;
          case "loading":
            return HStack({ spacing: 6 }, [ProgressView(), Text(t("import.loading", "Reading the spec")).font("caption").color("secondary")]).padding({ top: 4, leading: 12, bottom: 4, trailing: 12 });
          case "error":
            return Text(s.text).font("caption").color(s.missing ? "secondary" : "danger").lineLimit(4).padding({ top: 4, leading: 12, bottom: 4, trailing: 12 });
          case "ready":
            return previewCard(s.catalog, s.local);
        }
      },
      aboutLine()
    ]);
  }
  var shape = computed(() => loading() ? "loading" : loadProblem() ? "problem" : connections().length === 0 ? "empty" : "list");
  function homeState(emptyAction) {
    switch (shape()) {
      case "loading":
        return Text(t("home.loading", "Loading integrations")).font("caption").color("secondary").padding(12);
      case "problem":
        return problemState(loadProblem());
      case "empty":
        return VStack({ spacing: 8 }, [
          EmptyState({ title: t("home.empty", "No integrations yet"), message: t("home.empty.message", "Connect GitHub, Linear, Slack or any API so agents and automations can use it."), symbol: "puzzlepiece.extension" }),
          emptyAction ? HStack({ spacing: 0 }, [Spacer(), smallButton(t("action.connectFirst", "Connect an App"), () => open({ screen: "add" })), Spacer()]) : null
        ]);
      default:
        return null;
    }
  }
  var teamLine = () => {
    const p = teamPolicy();
    const text = p ? policySourceLabel(p) : null;
    return text ? Text(text).font("caption2").color("tertiary").padding({ top: 6, leading: 12, bottom: 8, trailing: 12 }) : null;
  };
  var summary = () => {
    const n = counts(connections());
    if (n.attention > 0)
      return Text(t("home.attention", "{n} need attention", { n: n.attention })).font("caption").color("warning").padding({ top: 0, leading: 12, bottom: 4, trailing: 12 });
    return null;
  };
  var connectionList = () => ForEach({ items: connections, key: (c) => c.id }, (c) => connectionRow(c, () => open({ screen: "detail", id: c().id })));
  function connectionsHome() {
    return VStack({ spacing: 0 }, [
      header(t("home.title", "Integrations"), [smallButton(t("action.add", "Add"), () => open({ screen: "add" }))]),
      noticeLine(),
      () => {
        shape();
        return untrack(() => homeState(true) ?? VStack({ spacing: 0 }, [() => summary(), connectionList()]));
      },
      () => teamLine()
    ]);
  }
  function galleryHome() {
    return VStack({ spacing: 0 }, [
      header(t("home.title", "Integrations")),
      noticeLine(),
      () => teamLine(),
      gallery(),
      () => {
        const k = shape();
        return untrack(() => k === "list" ? VStack({ spacing: 0 }, [sectionTitle(t("home.yours", "Your connections")), () => summary(), connectionList()]) : k === "problem" ? problemState(loadProblem()) : null);
      }
    ]);
  }
  var [filter, setFilter] = signal("");
  var activeIds = computed(() => connections().filter((c) => c.status === "active").map((c) => c.id).join(","));
  function catalogHome() {
    effect(() => {
      const ids = activeIds();
      untrack(() => {
        for (const c of connections())
          if (ids.split(",").includes(c.id))
            loadTools(c);
      });
    });
    return VStack({ spacing: 0 }, [
      header(t("catalog.title", "Tools"), [smallButton(t("action.add", "Add"), () => open({ screen: "add" }))]),
      noticeLine(),
      TextField(filter, { placeholder: t("catalog.filter", "Filter tools"), onEdit: setFilter, onCancel: () => setFilter("") }).padding({ top: 0, leading: 12, bottom: 6, trailing: 12 }),
      Text(t("catalog.help", "Allow runs without asking. Ask needs your approval each time. Block never runs.")).font("caption2").color("tertiary").lineLimit(2).padding({ top: 0, leading: 12, bottom: 4, trailing: 12 }),
      () => {
        const ids = activeIds();
        shape();
        return untrack(() => catalogSections(ids));
      },
      () => teamLine()
    ]);
  }
  function catalogSections(activeList) {
    return homeState(true) ?? VStack({ spacing: 0 }, activeList.split(",").filter(Boolean).map((id) => {
      const c = () => connections().find((x) => x.id === id);
      return VStack({ spacing: 0 }, [
        HStack({ spacing: 6 }, [Text(() => displayName(c())).font("caption").weight("semibold"), Spacer()]).padding({ top: 10, leading: 12, bottom: 2, trailing: 12 }).cursor("pointer").onTap(() => open({ screen: "detail", id })),
        toolList(c, filter, 25)
      ]);
    }));
  }
  function addView() {
    return VStack({ spacing: 0 }, [header(t("add.title", "Connect"), [], true), noticeLine(), gallery()]);
  }
  function paneView() {
    const screen = computed(() => {
      const r = route();
      return r.screen === "detail" ? `detail:${r.id}` : r.screen === "home" ? `home:${variant()}` : r.screen;
    });
    return VStack({ spacing: 0 }, [
      () => {
        const key = screen();
        return untrack(() => {
          if (key.startsWith("detail:"))
            return detailView(key.slice("detail:".length));
          if (key === "add")
            return addView();
          if (key === "import")
            return importView();
          if (key === "home:gallery")
            return galleryHome();
          if (key === "home:catalog")
            return catalogHome();
          return connectionsHome();
        });
      }
    ]);
  }
  function follow() {
    cmux.events.on("integration.changed", () => reload());
  }
  function renderSection(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    follow();
    reload();
    return sectionView((detail) => openIntegrations(detail ? { connection: detail } : {}));
  }
  function renderPane(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    if (typeof ctx.connection === "string")
      open({ screen: "detail", id: ctx.connection });
    follow();
    reload();
    return paneView();
  }
  var openIntegrations2 = openIntegrations;
  var connect3 = connect2;
  var importApi2 = importApi;
  var cycleVariant3 = cycleVariant2;
  globalThis.__cmuxAppExports = { ...exports_main };
})();
