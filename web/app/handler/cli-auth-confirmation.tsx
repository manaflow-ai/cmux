"use client";

import { MessageCard, useCliAuthConfirmation, useUser } from "@stackframe/stack";

export function CliAuthConfirmation({ fullPage = true }: { fullPage?: boolean }) {
  const cliAuth = useCliAuthConfirmation();
  const user = useUser({ includeRestricted: true });

  if (cliAuth.status === "success") {
    const email = user?.primaryEmail ?? "email unavailable";
    const organization = user?.selectedTeam?.displayName ?? "personal account";

    return (
      <MessageCard title={"Signed in to coderouter"} fullPage={fullPage}>
        <p>{"This terminal is now authorized. You can close this window and return to the command line."}</p>
        <dl className="mt-4 space-y-2 text-sm">
          <div>
            <dt className="font-medium">{"Email"}</dt>
            <dd>{email}</dd>
          </div>
          <div>
            <dt className="font-medium">{"Organization"}</dt>
            <dd>{organization}</dd>
          </div>
        </dl>
      </MessageCard>
    );
  }

  if (cliAuth.status === "error") {
    return <MessageCard title={"Authorization Failed"} fullPage={fullPage} primaryButtonText={"Try Again"} primaryAction={cliAuth.retry}>
      <p className="text-red-600">{"Failed to authorize the CLI application. Please try again."}</p>
    </MessageCard>;
  }

  if (cliAuth.status === "invalid") {
    return <MessageCard title={"Invalid CLI Authorization Link"} fullPage={fullPage}>
      <p className="text-red-600">{"This CLI authorization link is missing a login code. Please return to the command line and start the login process again."}</p>
    </MessageCard>;
  }

  if (cliAuth.status === "authorizing" || cliAuth.status === "redirecting") {
    return <MessageCard title={"Completing Authorization..."} fullPage={fullPage}>
      <p>{"Finishing up the CLI authorization..."}</p>
    </MessageCard>;
  }

  return <MessageCard title={"Authorize CLI Application"} fullPage={fullPage} primaryButtonText={cliAuth.isLoading ? "Authorizing..." : "Authorize"} primaryAction={cliAuth.authorize}>
    <p>{"A command line application is requesting access to your account. Click the button below to authorize it."}</p>
    <p className="text-red-600">{"WARNING: Make sure you trust the command line application, as it will gain access to your account. If you did not initiate this request, you can close this page and ignore it. We will never send you this link via email or any other means."}</p>
  </MessageCard>;
}
