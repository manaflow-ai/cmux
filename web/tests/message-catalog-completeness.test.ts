import { describe, expect, test } from "bun:test";
import { locales } from "../i18n/routing";
import englishMessages from "../messages/en.json";

describe("message catalog completeness", () => {
  test("defines every English message in every supported locale", async () => {
    const missing: string[] = [];

    for (const locale of locales) {
      if (locale === "en") continue;

      const messages = (
        await import(`../messages/${locale}.json`)
      ).default as unknown;
      missing.push(
        ...missingMessagePaths(englishMessages, messages).map(
          (path) => `${locale}:${path}`,
        ),
      );
    }

    expect(missing).toEqual([]);
  });

  test("preserves runtime literals and technical rich-text values", async () => {
    const mismatches: string[] = [];

    for (const locale of locales) {
      if (locale === "en") continue;

      const messages = (
        await import(`../messages/${locale}.json`)
      ).default as unknown;
      for (const { path, source, target } of pairedStringMessages(
        englishMessages,
        messages,
      )) {
        if (
          (source === "true" || source === "false") &&
          target !== source
        ) {
          mismatches.push(`${locale}:${path} boolean ${target}`);
        }

        const sourceCodeSpans = source.match(/`[^`]+`/gu) ?? [];
        const targetCodeSpans = target.match(/`[^`]+`/gu) ?? [];
        if (!arraysEqual(sourceCodeSpans, targetCodeSpans)) {
          mismatches.push(`${locale}:${path} code spans`);
        }

        const sourceTechnicalValues = technicalRichTextValues(source);
        const targetTechnicalValues = technicalRichTextValues(target);
        if (!arraysEqual(sourceTechnicalValues, targetTechnicalValues)) {
          mismatches.push(`${locale}:${path} technical rich text`);
        }

        const sourceProtectedTokens = protectedTokens(source);
        const missingProtectedTokens = sourceProtectedTokens.filter(
          (token) =>
            countProtectedTokenOccurrences(target, token, locale) <
            sourceProtectedTokens.filter(
              (sourceToken) => sourceToken === token,
            ).length,
        );
        if (missingProtectedTokens.length > 0) {
          mismatches.push(
            `${locale}:${path} protected tokens ` +
              `${missingProtectedTokens.join(", ")}`,
          );
        }
      }
    }

    expect(mismatches).toEqual([]);
  });

  test("provides translated legal documents in every supported locale", async () => {
    const english = englishMessages as unknown as LegalMessages;
    expect(english.legal.terms.title).toBe("Terms of Service");
    expect(english.legal.eula.title).toBe("EULA");

    for (const locale of locales) {
      if (locale === "en") continue;

      const messages = (
        await import(`../messages/${locale}.json`)
      ).default as unknown as LegalMessages;
      expect(messages.legal.terms.title).not.toBe(english.legal.terms.title);
      expect(messages.legal.terms.introduction.acceptance).not.toBe(
        english.legal.terms.introduction.acceptance,
      );
      expect(messages.legal.eula.introduction.readCarefully).not.toBe(
        english.legal.eula.introduction.readCarefully,
      );
      expect(messages.legal.eula.sections.license.scopeBody).not.toBe(
        english.legal.eula.sections.license.scopeBody,
      );
    }
  });
});

type LegalMessages = {
  legal: {
    terms: {
      title: string;
      introduction: { acceptance: string };
    };
    eula: {
      title: string;
      introduction: { readCarefully: string };
      sections: { license: { scopeBody: string } };
    };
  };
};

function missingMessagePaths(
  source: unknown,
  target: unknown,
  path = "",
): string[] {
  if (Array.isArray(source)) {
    if (!Array.isArray(target)) return [path];
    return source.flatMap((value, index) =>
      missingMessagePaths(value, target[index], `${path}[${index}]`),
    );
  }

  if (isRecord(source)) {
    if (!isRecord(target)) return [path];
    return Object.entries(source).flatMap(([key, value]) =>
      missingMessagePaths(
        value,
        target[key],
        path.length > 0 ? `${path}.${key}` : key,
      ),
    );
  }

  return target === undefined ||
    typeof target !== typeof source ||
    (typeof target === "string" && target.trim().length === 0)
    ? [path]
    : [];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function pairedStringMessages(
  source: unknown,
  target: unknown,
  path = "",
): Array<{ path: string; source: string; target: string }> {
  if (typeof source === "string" && typeof target === "string") {
    return [{ path, source, target }];
  }
  if (Array.isArray(source) && Array.isArray(target)) {
    return source.flatMap((value, index) =>
      pairedStringMessages(value, target[index], `${path}[${index}]`),
    );
  }
  if (isRecord(source) && isRecord(target)) {
    return Object.entries(source).flatMap(([key, value]) =>
      pairedStringMessages(
        value,
        target[key],
        path.length > 0 ? `${path}.${key}` : key,
      ),
    );
  }
  return [];
}

const technicalRichTextTags = [
  "action",
  "actions",
  "agent",
  "buttons",
  "checkbox",
  "chordShortcut",
  "code",
  "commands",
  "config",
  "configPath",
  "contextMenu",
  "customize",
  "defaultMenu",
  "defaultScale",
  "desktop",
  "emojiIcon",
  "falseValue",
  "globalConfig",
  "hooksMode",
  "imageIcon",
  "jumpShortcut",
  "legacy",
  "localConfig",
  "newBrowser",
  "newTerminal",
  "newWorkspaceMenu",
  "openShortcut",
  "palette",
  "path",
  "projectConfig",
  "replace",
  "rightClick",
  "saveLayout",
  "scale",
  "separator",
  "settingsFile",
  "shortcut",
  "singleShortcut",
  "splitDown",
  "splitRight",
  "setup",
  "symbolIcon",
  "target",
  "trueValue",
  "url",
  "worktree",
  "workspace",
] as const;

function technicalRichTextValues(message: string): string[] {
  const tagPattern = technicalRichTextTags.join("|");
  return [...message.matchAll(
    new RegExp(`<(${tagPattern})>(.*?)</\\1>`, "gsu"),
  )].map((match) => `${match[1]}:${match[2]}`).sort();
}

const protectedTokenPatterns = [
  /AGPL-3\.0/gu,
  /GPL-3\.0/gu,
  /remote\.tmux\.\*/gu,
  /remote\.tmux\.mirror/gu,
  /split-window/gu,
  /send-keys/gu,
  /capture-pane/gu,
  /refresh-client -C/gu,
  /swap-window/gu,
  /paste-buffer -p/gu,
  /cmux new-split/gu,
  /cmux top/gu,
  /cmux hooks setup/gu,
  /cmux ssh-tmux/gu,
  /cmux claude-teams/gu,
  /cmux omo/gu,
  /cmux notify/gu,
  /cmux mosh-tmux/gu,
  /cmux mosh(?!-tmux)/gu,
  /cmux ssh(?!-tmux)/gu,
  /cmux reload-config/gu,
  /ssh -L/gu,
  /worktrees\/\[task\]\s*\/\s*\[repo\]/gu,
  /AGENTS\.md/gu,
  /manaflow-ai\/[a-z0-9-]+/gu,
  /\$cmux-customization/gu,
  /oh-my-(?:opencode|openagent|codex|pi|claudecode)/gu,
  /omx doctor/gu,
  /cmux omx/gu,
  /cmux omc/gu,
] as const;

function protectedTokens(message: string): string[] {
  return protectedTokenPatterns
    .flatMap((pattern) => message.match(pattern) ?? [])
    .sort();
}

function countOccurrences(message: string, token: string): number {
  return message.split(token).length - 1;
}

const localesWithoutRequiredWordSpacing = new Set([
  "ja",
  "zh-CN",
  "zh-TW",
  "ko",
  "th",
  "km",
]);

function countProtectedTokenOccurrences(
  message: string,
  token: string,
  locale: string,
): number {
  if (localesWithoutRequiredWordSpacing.has(locale)) {
    return countOccurrences(message, token);
  }

  const escapedToken = token.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  return [...message.matchAll(
    new RegExp(`${escapedToken}(?![\\p{L}\\p{N}_])`, "gu"),
  )].length;
}

function arraysEqual(left: readonly string[], right: readonly string[]) {
  return left.length === right.length &&
    left.every((value, index) => value === right[index]);
}
