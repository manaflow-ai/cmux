import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import enMessages from "../messages/en.json";

let currentUser: {
  acceptTeamInvitation?: ReturnType<typeof mock>;
  listTeamInvitations?: ReturnType<typeof mock>;
} | null = null;
let redirectTarget: string | null = null;
const getUser = mock(async () => currentUser);
const redirect = mock((target: unknown) => {
  redirectTarget = String(target);
  throw new Error(`NEXT_REDIRECT:${target}`);
});

mock.module("next/navigation", () => ({ redirect }));
mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));
mock.module("next-intl/server", () => ({
  getTranslations: async (input?: string | { namespace?: string }) =>
    translator(typeof input === "string" ? input : input?.namespace),
}));
mock.module("../i18n/navigation", () => ({
  Link: ({ href, children, ...props }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...props}>{children}</a>
  ),
}));

const { default: TeamInviteAcceptPage } = await import("../app/[locale]/dashboard/team/accept/page");

describe("team invite accept page", () => {
  beforeEach(() => {
    redirectTarget = null;
    currentUser = null;
    getUser.mockClear();
    redirect.mockClear();
  });

  test("signed-out users bounce through vault sign-in with the accept return path", async () => {
    await expect(renderAccept("abc")).rejects.toThrow("NEXT_REDIRECT");

    expect(redirectTarget).toContain("/handler/sign-in");
    expect(decodeURIComponent(decodeURIComponent(redirectTarget ?? ""))).toContain(
      "/en/dashboard/team/accept?code=abc",
    );
  });

  test("accepts the Stack invitation and redirects to the team page", async () => {
    const acceptTeamInvitation = mock(async () => undefined);
    currentUser = { acceptTeamInvitation };

    await expect(renderAccept("abc")).rejects.toThrow("NEXT_REDIRECT");

    expect(acceptTeamInvitation).toHaveBeenCalledWith("abc");
    expect(redirectTarget).toBe("/en/dashboard/team?joined=1");
  });

  test("accepts branded invitation-id links through received invitations", async () => {
    const accept = mock(async () => undefined);
    currentUser = {
      listTeamInvitations: mock(async () => [{ id: "inv_1", accept }]),
    };

    await expect(renderAcceptInvitation("inv_1")).rejects.toThrow("NEXT_REDIRECT");

    expect(accept).toHaveBeenCalled();
    expect(redirectTarget).toBe("/en/dashboard/team?joined=1");
  });

  test("email mismatch renders a friendly switch-account error", async () => {
    currentUser = {
      acceptTeamInvitation: mock(async () => {
        throw new Error("TeamInvitationEmailMismatch");
      }),
    };

    const html = await renderAccept("abc");

    expect(html).toContain("Use the invited email address");
    expect(html).toContain("/handler/sign-out-and-sign-in");
  });
});

async function renderAccept(code: string): Promise<string> {
  const element = await TeamInviteAcceptPage({
    params: Promise.resolve({ locale: "en" }),
    searchParams: Promise.resolve({ code }),
  });
  return renderToStaticMarkup(element);
}

async function renderAcceptInvitation(invitation: string): Promise<string> {
  const element = await TeamInviteAcceptPage({
    params: Promise.resolve({ locale: "en" }),
    searchParams: Promise.resolve({ invitation }),
  });
  return renderToStaticMarkup(element);
}

function translator(namespace?: string) {
  return (key: string, values?: Record<string, string | number>) => {
    const path = [...(namespace?.split(".") ?? []), ...key.split(".")];
    let value: unknown = enMessages;
    for (const part of path) value = (value as Record<string, unknown>)?.[part];
    let text = typeof value === "string" ? value : key;
    for (const [name, replacement] of Object.entries(values ?? {})) {
      text = text.replaceAll(`{${name}}`, String(replacement));
    }
    return text;
  };
}
