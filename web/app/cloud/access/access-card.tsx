import Image from "next/image";

export type PublicationAccessView =
  | "signed-out"
  | "signed-in"
  | "invalid";

export type PublicationAccessMessages = {
  readonly title: string;
  readonly signIn: string;
  readonly signedInAs: string;
  readonly switchAccount: string;
  readonly invalidTitle: string;
  readonly invalidBody: string;
  readonly footer: string;
};

type PublicationAccessCardProps = {
  readonly view: PublicationAccessView;
  readonly hostname?: string | null;
  readonly identity?: string | null;
  readonly signInHref?: string | null;
  readonly switchAccountHref?: string | null;
  readonly messages: PublicationAccessMessages;
  readonly locale: string;
};

/**
 * One deliberately small surface for every protected-domain access state:
 * the app icon, one sentence, the hostname, and at most one action.
 * Authentication data is resolved by the server page; this component only
 * renders product-owned copy and opaque action targets.
 */
export function PublicationAccessCard({
  view,
  hostname,
  identity,
  signInHref,
  switchAccountHref,
  messages,
  locale,
}: PublicationAccessCardProps) {
  const invalid = view === "invalid";
  const direction = locale === "ar" ? "rtl" : "ltr";

  return (
    <main
      className="relative flex min-h-screen flex-col items-center justify-center bg-[#fafafa] px-6 pb-20 pt-12 text-[#171717]"
      dir={direction}
    >
      <section
        className="flex w-full max-w-[400px] flex-col items-center text-center"
        data-publication-access={view}
        lang={locale}
      >
        <Image
          alt=""
          className={invalid ? "opacity-50 grayscale" : undefined}
          height={64}
          priority
          src="/logo.png"
          width={64}
        />

        <h1 className="mt-6 text-balance text-2xl font-semibold leading-tight tracking-[-0.03em]">
          {invalid ? messages.invalidTitle : messages.title}
        </h1>

        {hostname && !invalid ? (
          <p
            className="mt-2 max-w-full truncate font-mono text-[13px] text-[#737373]"
            title={hostname}
          >
            {hostname}
          </p>
        ) : null}

        {invalid ? (
          <p className="mt-2 text-sm leading-6 text-[#555550]">
            {messages.invalidBody}
          </p>
        ) : null}

        {view === "signed-in" && identity ? (
          <IdentityPill
            identity={identity}
            label={messages.signedInAs.replace("{identity}", () => identity)}
          />
        ) : null}

        {view === "signed-in" && switchAccountHref ? (
          <a
            className="mt-3 text-[13px] text-[#0073d9] underline-offset-4 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#0073d9]"
            href={switchAccountHref}
          >
            {messages.switchAccount}
          </a>
        ) : null}

        {view === "signed-out" && signInHref ? (
          <a
            className="mt-7 inline-flex min-h-10 items-center justify-center rounded-full bg-[#171717] px-6 text-sm font-medium text-white transition-colors hover:bg-[#30302d] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#171717]"
            href={signInHref}
          >
            {messages.signIn}
          </a>
        ) : null}
      </section>

      <p className="absolute inset-x-0 bottom-7 px-6 text-center text-xs text-[#8a8a84]">
        {messages.footer}
      </p>
    </main>
  );
}

function IdentityPill({
  identity,
  label,
}: {
  readonly identity: string;
  readonly label: string;
}) {
  const initial = [...identity.trim()][0]?.toUpperCase() ?? "";
  return (
    <p className="mt-5 inline-flex max-w-full items-center gap-2 rounded-full border border-[#e5e5e5] bg-white py-1 pe-3 ps-1 text-[13px] text-[#30302d]">
      <span
        aria-hidden="true"
        className="grid size-6 shrink-0 place-items-center rounded-full text-[11px] font-semibold text-white"
        style={{ backgroundImage: "linear-gradient(135deg, #3cc3ff, #5b5cf6)" }}
      >
        {initial}
      </span>
      <span className="truncate">{label}</span>
    </p>
  );
}
