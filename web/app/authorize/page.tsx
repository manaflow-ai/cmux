import { redirect } from "next/navigation";

type AuthorizePageProps = {
  searchParams: Promise<{ code?: string | string[] }>;
};

const authorizationCode = (value: string | string[] | undefined): string | null => {
  const code = (Array.isArray(value) ? value[0] : value)?.trim();
  if (!code || code.length > 256 || !/^[a-zA-Z0-9_-]+$/.test(code)) {
    return null;
  }
  return code;
};

export default async function AuthorizePage({
  searchParams,
}: AuthorizePageProps) {
  const code = authorizationCode((await searchParams).code);
  if (code) {
    redirect(
      `/handler/cli-auth-confirm?login_code=${encodeURIComponent(code)}`,
    );
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-black px-6 text-white">
      <section className="w-full max-w-sm">
        <p className="mb-8 text-sm text-neutral-500">CodeRouter</p>
        <h1 className="text-2xl font-medium tracking-tight">
          Authorize a device
        </h1>
        <p className="mt-2 text-sm leading-6 text-neutral-400">
          Paste the authorization code shown by{" "}
          <code className="text-neutral-200">cr login --device-auth</code>.
        </p>
        <form className="mt-8 space-y-3">
          <label className="sr-only" htmlFor="code">
            Authorization code
          </label>
          <input
            autoCapitalize="none"
            autoComplete="one-time-code"
            autoCorrect="off"
            autoFocus
            className="h-11 w-full rounded-md border border-neutral-800 bg-neutral-950 px-3 font-mono text-sm outline-none placeholder:text-neutral-700 focus:border-neutral-600"
            id="code"
            name="code"
            placeholder="Paste code"
            required
            spellCheck={false}
          />
          <button
            className="h-11 w-full rounded-md bg-white text-sm font-medium text-black hover:bg-neutral-200"
            type="submit"
          >
            Continue
          </button>
        </form>
      </section>
    </main>
  );
}
