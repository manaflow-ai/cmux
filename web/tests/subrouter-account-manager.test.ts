import { describe, expect, test } from "bun:test";
import { createElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { AccountTable } from "../app/[locale]/dashboard/components/subrouter-account-manager";
import type { SubrouterAccount } from "../services/subrouter/client";

type AccountTableProps = Parameters<typeof AccountTable>[0];

const messages: Record<string, string> = {
  actionsColumn: "Actions",
  createdColumn: "Created",
  labelColumn: "Label",
  providerClaude: "Claude",
  providerColumn: "Provider",
  providerOpenAiApiKey: "OpenAI API key",
  unknownCreatedAt: "Unknown",
  unlabeledAccount: "Unlabeled",
};

const t = Object.assign((key: string): string => messages[key] ?? key, {
  has: (key: string): boolean => key in messages,
  markup: (key: string): string => messages[key] ?? key,
  raw: (key: string): string => messages[key] ?? key,
  rich: (key: string): string => messages[key] ?? key,
}) as unknown as AccountTableProps["t"];

const accounts: readonly SubrouterAccount[] = [
  {
    id: "acct-claude",
    kind: "claude",
    label: "Claude Team",
    createdAt: "2026-07-01T00:00:00.000Z",
  },
  {
    id: "acct-openai",
    kind: "openai-apikey",
    label: "OpenAI Team",
    createdAt: "2026-07-02T00:00:00.000Z",
  },
];

describe("AccountTable", () => {
  test("renders visible account numbers for each row", () => {
    const html = renderToStaticMarkup(
      createElement(AccountTable, {
        accounts,
        dateFormatter: new Intl.DateTimeFormat("en", {
          dateStyle: "medium",
          timeStyle: "short",
          timeZone: "UTC",
        }),
        renderDeleteButton: ({
          accountId,
        }: {
          readonly accountId: string;
          readonly teamId: string;
        }): ReactNode => createElement("button", { type: "button" }, `Delete ${accountId}`),
        selectedTeamId: "team-a",
        t,
      }),
    );

    expect(html).toContain("<div>#</div>");
    expect(html).toContain(">1</div>");
    expect(html).toContain(">2</div>");
    expect(html).toContain("Claude Team");
    expect(html).toContain("OpenAI Team");
  });
});
