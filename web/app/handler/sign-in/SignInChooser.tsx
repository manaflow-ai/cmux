"use client";

import { useState } from "react";
import Image from "next/image";
import Link from "next/link";
import { useStackApp } from "@stackframe/stack";
import type { SignInChooserMessages } from "./messages";
import {
  parseRememberedSignInAccounts,
  type RememberedSignInAccount,
  RECENT_SIGN_IN_ACCOUNTS_STORAGE_KEY,
} from "./recent-accounts";

type SignInChooserProps = {
  messages: SignInChooserMessages;
};

function readRememberedAccounts(): RememberedSignInAccount[] {
  if (typeof window === "undefined") return [];
  return parseRememberedSignInAccounts(
    window.localStorage.getItem(RECENT_SIGN_IN_ACCOUNTS_STORAGE_KEY),
  );
}

function initials(account: RememberedSignInAccount): string {
  const source = account.name ?? account.email ?? "cmux";
  const parts = source
    .split(/[\s@._-]+/)
    .map((part) => part.trim())
    .filter(Boolean);
  const value =
    parts.length >= 2 ? `${parts[0][0]}${parts[1][0]}` : source.slice(0, 1);
  return value.toUpperCase();
}

export function SignInChooser({ messages }: SignInChooserProps) {
  const app = useStackApp();
  const [accounts] = useState(readRememberedAccounts);
  const [pendingAccountID, setPendingAccountID] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function signIn(account: RememberedSignInAccount | null) {
    setError(null);
    setPendingAccountID(account?.id ?? "new");
    try {
      await app.signInWithOAuth("google");
    } catch {
      setPendingAccountID(null);
      setError(messages.signInFailed);
    }
  }

  return (
    <main className="min-h-screen bg-[#111111] px-5 py-8 text-white">
      <section className="mx-auto flex min-h-[calc(100vh-4rem)] w-full max-w-[420px] flex-col justify-center">
        <div>
          <Image
            src="/brand/app-icon-dark.png"
            alt=""
            width={56}
            height={56}
            className="mb-8 h-14 w-14 rounded-2xl"
          />
          <h1 className="text-[34px] font-semibold leading-tight tracking-normal text-zinc-100 sm:text-[40px]">
            {messages.title}
          </h1>
          <p className="mt-3 text-base text-zinc-400">
            {messages.continueProduct}
          </p>

          <div className="mt-8 overflow-hidden rounded-xl border border-white/12 bg-white/[0.03]">
            {accounts.map((account) => (
              <button
                key={account.id}
                className="grid w-full grid-cols-[44px_minmax(0,1fr)] items-center gap-3 border-b border-white/10 px-4 py-4 text-left transition last:border-b-0 hover:bg-white/[0.05] disabled:cursor-wait disabled:opacity-70"
                disabled={pendingAccountID !== null}
                onClick={() => signIn(account)}
                type="button"
              >
                <span className="flex h-10 w-10 items-center justify-center rounded-full bg-zinc-700 text-sm font-medium text-white">
                  {initials(account)}
                </span>
                <span className="min-w-0">
                  <span className="block truncate text-base font-medium text-zinc-100">
                    {account.name ?? account.email ?? account.id}
                  </span>
                  {account.email ? (
                    <span className="block truncate text-sm text-zinc-400">
                      {account.email}
                    </span>
                  ) : null}
                </span>
              </button>
            ))}

            <button
              className="grid w-full grid-cols-[44px_minmax(0,1fr)] items-center gap-3 border-t border-white/10 px-4 py-4 text-left transition first:border-t-0 hover:bg-white/[0.05] disabled:cursor-wait disabled:opacity-70"
              disabled={pendingAccountID !== null}
              onClick={() => signIn(null)}
              type="button"
            >
              <span className="flex h-10 w-10 items-center justify-center rounded-full border border-zinc-600 text-lg text-zinc-200">
                +
              </span>
              <span className="text-base font-medium text-zinc-100">
                {pendingAccountID === "new"
                  ? messages.loading
                  : accounts.length > 0
                    ? messages.useAnotherAccount
                    : messages.continueAction}
              </span>
            </button>
          </div>

          {error ? (
            <p className="mt-4 rounded-md border border-red-400/30 bg-red-500/10 px-4 py-3 text-sm text-red-100">
              {error}
            </p>
          ) : null}

          <p className="mt-6 text-sm leading-6 text-zinc-500">
            {messages.privacyPrefix}{" "}
            <Link className="font-medium text-zinc-300" href="/privacy">
              {messages.privacyPolicy}
            </Link>{" "}
            {messages.privacyMiddle}{" "}
            <Link className="font-medium text-zinc-300" href="/terms">
              {messages.termsOfService}
            </Link>
          </p>
        </div>
      </section>
    </main>
  );
}
