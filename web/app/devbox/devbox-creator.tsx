"use client";

import Link from "next/link";
import { useState } from "react";
import type { FormEvent } from "react";

type CreatedDevbox = {
  id: string;
  provider?: string;
  image?: string;
  imageVersion?: string;
  createdAt?: string;
};

type VmErrorBody = {
  error?: string;
  message?: string;
  action?: string;
  reason?: string;
};

function createIdempotencyKey() {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function userMessage(status: number, body: VmErrorBody | null) {
  if (status === 401) {
    return "Sign in first, then create the devbox again.";
  }

  const pieces = [body?.message, body?.action ?? body?.reason].filter(
    Boolean,
  );
  return pieces.join(" ") || `Devbox create failed with status ${status}.`;
}

export function DevboxCreator() {
  const [prompt, setPrompt] = useState("");
  const [isCreating, setIsCreating] = useState(false);
  const [created, setCreated] = useState<CreatedDevbox | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (isCreating) return;

    setIsCreating(true);
    setError(null);
    setCreated(null);

    try {
      const response = await fetch("/api/vm", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "idempotency-key": createIdempotencyKey(),
        },
        body: JSON.stringify({
          initialPrompt: prompt.trim() || undefined,
          source: "devbox.new",
        }),
      });

      const body = (await response.json().catch(() => null)) as
        | CreatedDevbox
        | VmErrorBody
        | null;

      if (!response.ok) {
        setError(userMessage(response.status, body as VmErrorBody | null));
        return;
      }

      setCreated(body as CreatedDevbox);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Devbox create failed.");
    } finally {
      setIsCreating(false);
    }
  }

  return (
    <div className="w-full">
      <div className="mb-8 text-center">
        <h1 className="text-3xl font-semibold tracking-tight sm:text-5xl">
          Create a devbox
        </h1>
        <p className="mx-auto mt-4 max-w-xl text-base leading-7 text-muted sm:text-lg">
          Start a fresh cmux Cloud VM. Add the first prompt now, attach from
          cmux when it is ready.
        </p>
      </div>

      <form onSubmit={submit} className="space-y-4">
        <label htmlFor="devbox-prompt" className="sr-only">
          Initial prompt
        </label>
        <textarea
          id="devbox-prompt"
          value={prompt}
          onChange={(event) => setPrompt(event.target.value)}
          placeholder="What should this devbox work on?"
          rows={5}
          className="min-h-36 w-full resize-y rounded-lg border border-border bg-background px-4 py-3 text-base leading-6 outline-none transition-colors placeholder:text-muted focus:border-foreground"
        />
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <Link
            href="/handler/sign-in?after_auth_return_to=/devbox"
            className="text-sm text-muted underline underline-offset-4 transition-colors hover:text-foreground"
          >
            Sign in
          </Link>
          <button
            type="submit"
            disabled={isCreating}
            className="inline-flex h-11 items-center justify-center rounded-md bg-foreground px-5 text-sm font-medium text-background transition-opacity disabled:cursor-not-allowed disabled:opacity-55"
          >
            {isCreating ? "Creating..." : "Create devbox"}
          </button>
        </div>
      </form>

      {error ? (
        <p
          role="alert"
          className="mt-5 rounded-md border border-red-500/35 bg-red-500/10 px-4 py-3 text-sm leading-6 text-foreground"
        >
          {error}
        </p>
      ) : null}

      {created ? (
        <section className="mt-6 rounded-lg border border-border bg-code-bg p-4">
          <h2 className="text-sm font-semibold">Devbox created</h2>
          <dl className="mt-3 grid gap-2 text-sm">
            <div className="flex flex-wrap gap-x-3 gap-y-1">
              <dt className="text-muted">ID</dt>
              <dd className="font-mono">{created.id}</dd>
            </div>
            {created.provider ? (
              <div className="flex flex-wrap gap-x-3 gap-y-1">
                <dt className="text-muted">Provider</dt>
                <dd>{created.provider}</dd>
              </div>
            ) : null}
          </dl>
          <div className="mt-4 space-y-2">
            <code className="block overflow-x-auto rounded-md border border-border bg-background px-3 py-2 text-sm">
              cmux vm attach {created.id}
            </code>
            <code className="block overflow-x-auto rounded-md border border-border bg-background px-3 py-2 text-sm">
              cmux vm ssh {created.id}
            </code>
          </div>
        </section>
      ) : null}
    </div>
  );
}
