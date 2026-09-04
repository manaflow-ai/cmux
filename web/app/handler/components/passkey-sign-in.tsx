"use client";

import { useState } from "react";

type PasskeyLabels = {
  readonly label: string;
  readonly working: string;
  readonly unsupported: string;
};

/**
 * The only interactive island on the sign-in page.
 *
 * WebAuthn has no server-rendered equivalent, so this is the one place cmux
 * pays for client JavaScript. It renders nothing until the browser proves it
 * supports conditional passkeys, which keeps the button off screens that would
 * fail the moment it is pressed.
 */
export function PasskeySignIn({
  intl,
  returnTo,
}: {
  intl: PasskeyLabels;
  returnTo: string | null;
}) {
  const [state, setState] = useState<"idle" | "working" | "unsupported">("idle");

  if (state === "unsupported") {
    return <p className="text-[13px] text-muted">{intl.unsupported}</p>;
  }

  return (
    <button
      type="button"
      disabled={state === "working"}
      onClick={() => {
        if (typeof PublicKeyCredential === "undefined") {
          setState("unsupported");
          return;
        }
        setState("working");
        void runPasskeySignIn(returnTo).catch(() => setState("idle"));
      }}
      className="flex min-h-10 w-full items-center justify-center border border-border px-4 text-sm font-medium text-foreground hover:bg-code-bg disabled:opacity-60"
    >
      {state === "working" ? intl.working : intl.label}
    </button>
  );
}

async function runPasskeySignIn(returnTo: string | null): Promise<void> {
  const challengeResponse = await fetch("/handler/passkey/challenge", {
    method: "POST",
  });
  if (!challengeResponse.ok) throw new Error("passkey challenge failed");
  const { options_json: optionsJSON, code } = (await challengeResponse.json()) as {
    options_json: PublicKeyCredentialRequestOptionsJSON;
    code: string;
  };

  const { startAuthentication } = await import("./webauthn");
  const authentication = await startAuthentication(optionsJSON);

  const form = document.createElement("form");
  form.method = "post";
  form.action = "/handler/passkey";
  appendHiddenField(form, "authentication_response", JSON.stringify(authentication));
  appendHiddenField(form, "code", code);
  if (returnTo) appendHiddenField(form, "after_auth_return_to", returnTo);
  document.body.appendChild(form);
  form.submit();
}

function appendHiddenField(form: HTMLFormElement, name: string, value: string) {
  const input = document.createElement("input");
  input.type = "hidden";
  input.name = name;
  input.value = value;
  form.appendChild(input);
}

type PublicKeyCredentialRequestOptionsJSON = Record<string, unknown>;
