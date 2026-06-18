import { spawn } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";
import {
  flatNavItems,
  navItems,
} from "../app/[locale]/components/docs-nav-items";
import { changelogMedia } from "../app/[locale]/docs/changelog/changelog-media";
import { routing } from "../i18n/routing";

const projectRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const repoRoot = path.resolve(projectRoot, "..");
const siteDir = path.join(projectRoot, ".pagefind-site");
const outputDir = path.join(projectRoot, "public", "pagefind");
const rawMessagesCache = new Map();
const mergedMessagesCache = new Map();

const searchAliases = {
  apiReference: [
    "CLI reference",
    "cmux CLI",
    "command line",
    "API reference",
    "socket API",
    "JSON RPC",
    "automation API",
    "workspace.list",
    "surface.send_text",
  ],
  browserAutomation: [
    "browser CLI",
    "webview automation",
    "snapshot",
    "click",
    "fill",
    "console logs",
  ],
  claudeCodeTeams: ["Claude teams", "teammate mode", "tmux shim"],
  configuration: ["settings.json", "cmux.json", "Ghostty config"],
  customCommands: ["command palette", "project commands", "cmux.json"],
  dock: ["dock", "agent dock", "workspace dock"],
  notifications: ["OSC 777", "OSC 99", "hooks", "notification rings"],
  ohMyClaudeCode: ["omc", "oh my claude", "oh-my-claudecode"],
  ohMyCodex: ["omx", "oh my codex", "oh-my-codex"],
  ohMyOpenCode: ["omo", "oh-my-opencode", "oh-my-openagent"],
  ssh: ["remote sessions", "SSH relay", "scp uploads"],
};

const docsPageMessageKeys = {
  apiReference: "api",
};

export function docsSearchRoutes() {
  const links = flatNavItems(navItems);
  return routing.locales.flatMap((locale) =>
    links.map((navItem) => ({
      locale,
      navItem,
      href: navItem.href,
      path: localizedDocsPath(locale, navItem.href),
    })),
  );
}

export function localizedDocsPath(locale, href) {
  return locale === routing.defaultLocale ? href : `/${locale}${href}`;
}

async function main() {
  const startedAt = Date.now();
  await rm(siteDir, { force: true, recursive: true });
  await rm(outputDir, { force: true, recursive: true });
  await mkdir(siteDir, { recursive: true });

  const pages = await docsSearchPages();

  try {
    await Promise.all(pages.map(writePageHtml));
    await runPagefind();
    const elapsedSeconds = ((Date.now() - startedAt) / 1000).toFixed(2);
    console.log(
      `Docs search index built for ${pages.length} localized pages in ${elapsedSeconds}s`,
    );
  } finally {
    await rm(siteDir, { force: true, recursive: true });
  }
}

export async function docsSearchPages() {
  const contentByHref = await docsContentByHref();
  const changelogText = await changelogSearchText();
  const routes = docsSearchRoutes();
  const pages = [];

  for (const route of routes) {
    const messages = await messagesForLocale(route.locale);
    const docsMessages = getObject(messages, ["docs"]);
    const pageMessages = getObject(docsMessages, [
      docsPageMessageKeys[route.navItem.titleKey] ?? route.navItem.titleKey,
    ]);
    const navMessages = getObject(docsMessages, ["navItems"]);
    const navTitle = getString(navMessages, [route.navItem.titleKey]);
    const title = getString(pageMessages, ["title"]) || navTitle;
    const description =
      getString(pageMessages, ["metaDescription"]) ||
      getString(pageMessages, ["intro"]);
    const content = contentByHref.get(route.href) ?? { entries: [], headings: [] };
    const headings = content.headings
      .map((heading) => ({
        ...heading,
        text: heading.key
          ? getString(pageMessages, [heading.key]) || heading.text
          : heading.text,
      }))
      .filter((heading) => heading.id && heading.text);
    const sections = docsSearchSections({
      changelogText: route.navItem.titleKey === "changelog" ? changelogText : [],
      description,
      entries: content.entries,
      headings,
      pageMessages,
      searchAliases: searchAliases[route.navItem.titleKey] ?? [],
      title,
      navTitle,
    });

    pages.push({
      ...route,
      title,
      description,
      headings,
      sections,
    });
  }

  return pages;
}

function docsSearchSections({
  changelogText,
  description,
  entries,
  headings,
  navTitle,
  pageMessages,
  searchAliases,
  title,
}) {
  const titleHeading = headings.find((heading) => heading.level === 1) ?? {
    id: "title",
    level: 1,
    text: title,
  };
  const orderedHeadings = [
    titleHeading,
    ...headings.filter((heading) => heading.id !== titleHeading.id),
  ];
  const sections = new Map();
  const seen = new Set();

  function ensureSection(heading) {
    if (!sections.has(heading.id)) {
      sections.set(heading.id, {
        id: heading.id,
        level: heading.level,
        text: heading.text,
        texts: [],
      });
    }
    return sections.get(heading.id);
  }

  function addText(section, value) {
    const normalized = normalizeSearchText(value ?? "");
    if (!normalized || seen.has(normalized)) return;
    seen.add(normalized);
    section.texts.push(normalized);
  }

  for (const heading of orderedHeadings) {
    ensureSection(heading);
  }

  const titleSection = ensureSection(titleHeading);
  for (const text of [navTitle, title, description]) {
    addText(titleSection, text);
  }

  for (const entry of entries) {
    if (entry.type !== "text") continue;
    const section = sections.get(entry.headingId) ?? titleSection;
    const text = entry.key
      ? getString(pageMessages, [entry.key]) || entry.text
      : entry.text;
    addText(section, text);
  }

  for (const text of [...searchAliases, ...changelogText]) {
    addText(titleSection, text);
  }

  return Array.from(sections.values());
}

async function messagesForLocale(locale) {
  if (!mergedMessagesCache.has(locale)) {
    const promise = (async () => {
      const defaultMessages = await readMessages(routing.defaultLocale);
      if (locale === routing.defaultLocale) return defaultMessages;
      return deepMerge(defaultMessages, await readMessages(locale));
    })();
    mergedMessagesCache.set(locale, promise);
    promise.catch(() => {
      mergedMessagesCache.delete(locale);
    });
  }
  return mergedMessagesCache.get(locale);
}

async function readMessages(locale) {
  if (!rawMessagesCache.has(locale)) {
    const promise = (async () => {
      const filePath = path.join(projectRoot, "messages", `${locale}.json`);
      return JSON.parse(await readFile(filePath, "utf8"));
    })();
    rawMessagesCache.set(locale, promise);
    promise.catch(() => {
      rawMessagesCache.delete(locale);
    });
  }
  return rawMessagesCache.get(locale);
}

function deepMerge(base, override) {
  const result = { ...base };

  for (const [key, overrideValue] of Object.entries(override)) {
    const baseValue = result[key];
    if (isRecord(baseValue) && isRecord(overrideValue)) {
      result[key] = deepMerge(baseValue, overrideValue);
    } else {
      result[key] = overrideValue;
    }
  }

  return result;
}

function docsPageSourcePath(href) {
  const docsPath = href.replace(/^\//, "");
  return path.join(projectRoot, "app", "[locale]", docsPath, "page.tsx");
}

async function docsContentByHref() {
  const content = new Map();
  await Promise.all(
    flatNavItems(navItems).map(async (item) => {
      const sourcePath = docsPageSourcePath(item.href);
      try {
        content.set(
          item.href,
          extractDocsContent(await readFile(sourcePath, "utf8")),
        );
      } catch (error) {
        console.warn(
          `Docs search skipped source content for ${item.href}: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
        content.set(item.href, { entries: [], headings: [] });
      }
    }),
  );
  return content;
}

function extractDocsContent(sourceText) {
  const sourceFile = ts.createSourceFile(
    "page.tsx",
    sourceText,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
  );
  const constants = collectStringConstants(sourceFile);
  const defaultFunction = defaultExportFunction(sourceFile);
  const root = defaultFunction?.body ?? sourceFile;
  const entries = [];
  const headings = [];
  let currentHeadingId = "";

  function visit(node) {
    if (ts.isJsxElement(node)) {
      const tagName = node.openingElement.tagName.getText(sourceFile);
      if (tagName === "DocsHeading") {
        const id = stringAttributeValue(node.openingElement, "id");
        const level = numberAttributeValue(node.openingElement, "level") ?? 2;
        const text = headingText(node.children, sourceFile, constants);
        if (id && (text.key || text.text)) {
          headings.push({
            id,
            key: text.key,
            level,
            text: text.text ? normalizeSearchText(text.text) : "",
          });
          currentHeadingId = id;
        }
        return;
      }

      if (tagName === "CodeBlock") {
        for (const item of jsxChildrenTexts(node.children, sourceFile, constants)) {
          entries.push({ headingId: currentHeadingId, ...item, type: "text" });
        }
        return;
      }
    }

    if (ts.isJsxSelfClosingElement(node) || ts.isJsxOpeningElement(node)) {
      for (const item of searchableAttributeTexts(node, sourceFile, constants)) {
        entries.push({ headingId: currentHeadingId, ...item, type: "text" });
      }
    }

    if (ts.isJsxExpression(node) && node.expression) {
      const key = translationKey(node.expression);
      if (key) {
        entries.push({ headingId: currentHeadingId, key, type: "text" });
      } else {
        const text = expressionLiteralText(node.expression, sourceFile, constants);
        if (text) entries.push({ headingId: currentHeadingId, text, type: "text" });
      }
    }

    if (ts.isJsxText(node)) {
      const text = normalizeSearchText(node.text);
      if (text) entries.push({ headingId: currentHeadingId, text, type: "text" });
    }

    ts.forEachChild(node, visit);
  }

  visit(root);
  return { entries, headings };
}

function collectStringConstants(sourceFile) {
  const constants = new Map();

  function visit(node) {
    if (
      ts.isVariableDeclaration(node) &&
      ts.isIdentifier(node.name) &&
      node.initializer
    ) {
      const value = expressionLiteralText(node.initializer, sourceFile, constants);
      if (value) constants.set(node.name.text, value);
      if (ts.isObjectLiteralExpression(node.initializer)) {
        for (const property of node.initializer.properties) {
          if (
            ts.isPropertyAssignment(property) &&
            (ts.isIdentifier(property.name) || ts.isStringLiteral(property.name))
          ) {
            const propertyValue = expressionLiteralText(
              property.initializer,
              sourceFile,
              constants,
            );
            if (propertyValue) {
              constants.set(`${node.name.text}.${property.name.text}`, propertyValue);
            }
          }
        }
      }
    }

    ts.forEachChild(node, visit);
  }

  visit(sourceFile);
  return constants;
}

function defaultExportFunction(sourceFile) {
  let result;

  function visit(node) {
    if (
      ts.isFunctionDeclaration(node) &&
      node.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword) &&
      node.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.DefaultKeyword)
    ) {
      result = node;
      return;
    }

    ts.forEachChild(node, visit);
  }

  visit(sourceFile);
  return result;
}

function jsxChildrenTexts(children, sourceFile, constants) {
  const texts = [];

  for (const child of children) {
    if (ts.isJsxText(child)) {
      const text = normalizeSearchText(child.text);
      if (text) texts.push({ text });
      continue;
    }

    if (ts.isJsxExpression(child) && child.expression) {
      const key = translationKey(child.expression);
      if (key) {
        texts.push({ key });
        continue;
      }

      const text = expressionLiteralText(child.expression, sourceFile, constants);
      if (text) texts.push({ text });
    }
  }

  return texts;
}

const searchableAttributeNames = new Set([
  "alt",
  "cli",
  "desc",
  "name",
  "socket",
  "title",
]);

function searchableAttributeTexts(openingElement, sourceFile, constants) {
  const texts = [];

  for (const property of openingElement.attributes.properties) {
    if (!ts.isJsxAttribute(property) || !searchableAttributeNames.has(property.name.text)) {
      continue;
    }
    if (!property.initializer) continue;

    if (ts.isStringLiteral(property.initializer)) {
      const text = normalizeSearchText(property.initializer.text);
      if (text) texts.push({ text });
      continue;
    }

    if (ts.isJsxExpression(property.initializer) && property.initializer.expression) {
      const key = translationKey(property.initializer.expression);
      if (key) {
        texts.push({ key });
        continue;
      }

      const text = expressionLiteralText(
        property.initializer.expression,
        sourceFile,
        constants,
      );
      if (text) texts.push({ text });
    }
  }

  return texts;
}

function stringAttributeValue(openingElement, name) {
  const attribute = openingElement.attributes.properties.find(
    (property) => ts.isJsxAttribute(property) && property.name.text === name,
  );
  if (!attribute || !ts.isJsxAttribute(attribute) || !attribute.initializer) {
    return "";
  }
  if (ts.isStringLiteral(attribute.initializer)) {
    return attribute.initializer.text;
  }
  if (
    ts.isJsxExpression(attribute.initializer) &&
    attribute.initializer.expression &&
    ts.isStringLiteral(attribute.initializer.expression)
  ) {
    return attribute.initializer.expression.text;
  }
  return "";
}

function numberAttributeValue(openingElement, name) {
  const attribute = openingElement.attributes.properties.find(
    (property) => ts.isJsxAttribute(property) && property.name.text === name,
  );
  if (
    !attribute ||
    !ts.isJsxAttribute(attribute) ||
    !attribute.initializer ||
    !ts.isJsxExpression(attribute.initializer) ||
    !attribute.initializer.expression
  ) {
    return undefined;
  }
  const expression = attribute.initializer.expression;
  return ts.isNumericLiteral(expression) ? Number(expression.text) : undefined;
}

function headingText(children, sourceFile, constants) {
  for (const child of children) {
    if (ts.isJsxText(child)) {
      const text = normalizeSearchText(child.text);
      if (text) return { text };
    }
    if (ts.isJsxExpression(child) && child.expression) {
      const key = translationKey(child.expression);
      if (key) return { key };
      const text = expressionLiteralText(child.expression, sourceFile, constants);
      if (text) return { text };
    }
    if (ts.isJsxElement(child)) {
      const nested = headingText(child.children, sourceFile, constants);
      if (nested.key || nested.text) return nested;
    }
  }
  return { text: "" };
}

function translationKey(expression) {
  if (
    ts.isCallExpression(expression) &&
    (expression.expression.getText() === "t" ||
      expression.expression.getText() === "t.rich") &&
    expression.arguments.length > 0 &&
    ts.isStringLiteral(expression.arguments[0])
  ) {
    return expression.arguments[0].text;
  }
  return "";
}

function expressionLiteralText(expression, sourceFile, constants) {
  if (ts.isStringLiteral(expression) || ts.isNoSubstitutionTemplateLiteral(expression)) {
    return expression.text;
  }
  const constantText = expressionConstantText(expression, sourceFile, constants);
  if (constantText) {
    return constantText;
  }
  if (sourceFile && ts.isTemplateExpression(expression)) {
    let text = expression.head.text;
    for (const span of expression.templateSpans) {
      text += expressionConstantText(span.expression, sourceFile, constants) || " ";
      text += span.literal.text;
    }
    return normalizeSearchText(text);
  }
  return "";
}

function expressionConstantText(expression, sourceFile, constants) {
  if (!constants) return "";
  if (ts.isIdentifier(expression)) {
    return constants.get(expression.text) ?? "";
  }
  if (sourceFile && ts.isPropertyAccessExpression(expression)) {
    return constants.get(expression.getText(sourceFile)) ?? "";
  }
  return "";
}

async function changelogSearchText() {
  const markdown = await readFile(path.join(repoRoot, "CHANGELOG.md"), "utf8");
  const markdownText = markdown
    .split("\n")
    .map((line) =>
      normalizeSearchText(
        line
          .replace(/^#+\s*/, "")
          .replace(/^-\s*/, "")
          .replace(/!\[[^\]]*]\([^)]+\)/g, "")
          .replace(/\[([^\]]+)]\([^)]+\)/g, "$1")
          .replace(/`([^`]+)`/g, "$1"),
      ),
    )
    .filter(Boolean);

  const mediaText = Object.values(changelogMedia).flatMap((version) => [
    version.title,
    ...(version.features ?? []).flatMap((feature) => [
      feature.title,
      feature.description,
    ]),
  ]);

  return uniqueText([...markdownText, ...mediaText]);
}

async function writePageHtml(page) {
  const filePath = path.join(siteDir, page.path.slice(1), "index.html");
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, pageHtml(page));
}

function pageHtml(page) {
  const sections = page.sections
    .map((section) => {
      const level = Math.min(Math.max(section.level, 1), 3);
      const titleMeta = level === 1 ? ' data-pagefind-meta="title"' : "";
      const heading = `<h${level} id="${escapeAttribute(section.id)}"${titleMeta}>${escapeHtml(section.text)}</h${level}>`;
      const body = section.texts
        .map((text, index) => {
          const weight = level === 1 && index < 3 ? 4 : 1;
          return `<p data-pagefind-weight="${weight}">${escapeHtml(text)}</p>`;
        })
        .join("\n");
      return `${heading}\n${body}`;
    })
    .join("\n");

  return `<!doctype html>
<html lang="${escapeHtml(page.locale)}">
<head>
  <meta charset="utf-8">
  <title>${escapeHtml(page.title)}</title>
  <meta name="description" content="${escapeHtml(page.description)}">
</head>
<body>
  <main
    data-pagefind-body
    data-pagefind-meta="section:Docs"
    data-pagefind-filter="locale:${escapeHtml(page.locale)}"
  >
    ${sections}
  </main>
</body>
</html>`;
}

async function runPagefind() {
  await runCommand(process.execPath, [
    "x",
    "pagefind",
    "--site",
    siteDir,
    "--output-path",
    outputDir,
    "--glob",
    "**/*.html",
  ]);
}

async function runCommand(command, args) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: projectRoot,
      env: process.env,
      stdio: "inherit",
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${command} ${args.join(" ")} exited with ${code}`));
      }
    });
  });
}

function getObject(value, keys) {
  let current = value;
  for (const key of keys) {
    if (!isRecord(current)) return {};
    current = current[key];
  }
  return isRecord(current) ? current : {};
}

function getString(value, keys) {
  let current = value;
  for (const key of keys) {
    if (!isRecord(current)) return "";
    current = current[key];
  }
  return typeof current === "string" ? normalizeSearchText(current) : "";
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeSearchText(value) {
  return value
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function uniqueText(values) {
  const seen = new Set();
  const texts = [];

  for (const value of values) {
    const normalized = normalizeSearchText(value);
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    texts.push(normalized);
  }

  return texts;
}

function escapeHtml(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeAttribute(value) {
  return escapeHtml(value).replace(/'/g, "&#39;");
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
