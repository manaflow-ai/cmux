"use client";

import { MessageCard, useCliAuthConfirmation, useUser, type CliAuthConfirmationState } from "@hexclave/next";
import { SIGN_IN_PATH } from "../lib/auth-paths";

export type CliAuthIdentityMessages = {
  email: string;
  emailUnavailable: string;
  organization: string;
  personalAccount: string;
  switchAccountButton: string;
  signedOutTitle: string;
  signedOutBody: string;
  signInButton: string;
};

export function CliAuthConfirmation({ fullPage = true, identityMessages }: {
  fullPage?: boolean;
  identityMessages: CliAuthIdentityMessages;
}) {
  const cliAuth = useCliAuthConfirmation();
  const user = useUser({ includeRestricted: true });
  const { children, ...cardProps } = user
    ? cliAuthMessage(cliAuth, identityMessages.switchAccountButton)
    : signedOutMessage(cliAuth, identityMessages);

  return (
    <MessageCard {...cardProps} fullPage={fullPage}>
      {user && (
        <dl className="space-y-2 text-sm">
          <div>
            <dt className="font-medium">{identityMessages.email}</dt>
            <dd className="break-words"><bdi>{user.primaryEmail ?? identityMessages.emailUnavailable}</bdi></dd>
          </div>
          <div>
            <dt className="font-medium">{identityMessages.organization}</dt>
            <dd className="break-words"><bdi>{user.selectedTeam?.displayName ?? identityMessages.personalAccount}</bdi></dd>
          </div>
        </dl>
      )}
      {children}
    </MessageCard>
  );
}

// A signed-out browser has no account to show. Stack's authorize action
// already sends it to sign-in and finishes the CLI login on return, so only
// the idle prompt changes.
function signedOutMessage(cliAuth: CliAuthConfirmationState, messages: CliAuthIdentityMessages) {
  if (cliAuth.status !== "idle") return cliAuthMessage(cliAuth, messages.switchAccountButton);
  return {
    title: messages.signedOutTitle,
    primaryButtonText: messages.signInButton,
    primaryAction: cliAuth.authorize,
    ...switchAccountProps(cliAuth.loginCode, messages.switchAccountButton),
    children: <p>{messages.signedOutBody}</p>,
  };
}

export function cliAuthSwitchAccountHref(loginCode: string): string {
  const confirmation = new URL("/handler/cli-auth-confirm", "https://cmux.com");
  confirmation.searchParams.set("login_code", loginCode);

  const signIn = new URL(SIGN_IN_PATH, "https://cmux.com");
  signIn.searchParams.set("after_auth_return_to", `${confirmation.pathname}${confirmation.search}`);

  const signOut = new URL("/handler/sign-out-and-sign-in", "https://cmux.com");
  signOut.searchParams.set("after_auth_return_to", `${signIn.pathname}${signIn.search}`);
  return `${signOut.pathname}${signOut.search}`;
}

function switchAccountProps(loginCode: string | null, label: string) {
  if (!loginCode) return {};
  const href = cliAuthSwitchAccountHref(loginCode);
  return {
    secondaryButtonText: label,
    secondaryAction: () => window.location.assign(href),
  };
}

// Every screen that still has a usable login code offers the account switch.
// Success is the exception: Stack has consumed the code, so a switch would
// return to a confirmation that can only fail.
function cliAuthMessage(cliAuth: CliAuthConfirmationState, switchAccountButton: string) {
  const accountSwitch = switchAccountProps(cliAuth.loginCode, switchAccountButton);

  if (cliAuth.status === "success") {
    return {
      title: "Signed in to coderouter",
      children: <p>{"This terminal is now authorized. You can close this window and return to the command line."}</p>,
    };
  }
  if (cliAuth.status === "error") {
    return {
      title: "Authorization Failed",
      primaryButtonText: "Try Again",
      primaryAction: cliAuth.retry,
      ...accountSwitch,
      children: <p className="text-red-600">{"Failed to authorize the CLI application. Please try again."}</p>,
    };
  }

  if (cliAuth.status === "invalid") {
    return {
      title: "Invalid CLI Authorization Link",
      children: <p className="text-red-600">{"This CLI authorization link is missing a login code. Please return to the command line and start the login process again."}</p>,
    };
  }

  if (cliAuth.status === "authorizing" || cliAuth.status === "redirecting") {
    return {
      title: "Completing Authorization...",
      ...accountSwitch,
      children: <p>{"Finishing up the CLI authorization..."}</p>,
    };
  }

  return {
    title: "Authorize CLI Application",
    primaryButtonText: cliAuth.isLoading ? "Authorizing..." : "Authorize",
    primaryAction: cliAuth.authorize,
    ...accountSwitch,
    children: <>
      <p>{"A command line application is requesting access to your account. Click the button below to authorize it."}</p>
      <p className="text-red-600">{"WARNING: Make sure you trust the command line application, as it will gain access to your account. If you did not initiate this request, you can close this page and ignore it. We will never send you this link via email or any other means."}</p>
    </>,
  };
}
