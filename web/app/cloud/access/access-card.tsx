export type PublicationAccessView =
  | "signed-out"
  | "signed-in"
  | "invalid";

export type PublicationAccessMessages = {
  readonly eyebrow: string;
  readonly title: string;
  readonly signedOutBody: string;
  readonly signIn: string;
  readonly signedInAs: string;
  readonly invalidTitle: string;
  readonly invalidBody: string;
  readonly footer: string;
};

type PublicationAccessCardProps = {
  readonly view: PublicationAccessView;
  readonly hostname?: string | null;
  readonly identity?: string | null;
  readonly signInHref?: string | null;
  readonly messages: PublicationAccessMessages;
  readonly locale: string;
};

/**
 * One deliberately small surface for every protected-domain access state.
 * Authentication data is resolved by the server page; this component only
 * renders product-owned copy and opaque action targets.
 */
export function PublicationAccessCard({
  view,
  hostname,
  identity,
  signInHref,
  messages,
  locale,
}: PublicationAccessCardProps) {
  const invalid = view === "invalid";
  const direction = locale === "ar" ? "rtl" : "ltr";

  return (
    <main
      className="relative flex min-h-screen items-center justify-center overflow-hidden bg-[#f7f7f5] px-5 py-12 text-[#171717]"
      dir={direction}
    >
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 opacity-[0.32]"
        style={{
          backgroundImage:
            "linear-gradient(to right, #deded9 1px, transparent 1px), linear-gradient(to bottom, #deded9 1px, transparent 1px)",
          backgroundSize: "32px 32px",
          maskImage:
            "radial-gradient(circle at center, black 0%, transparent 72%)",
        }}
      />

      <section
        className="relative w-full max-w-[460px] border border-black/[0.12] bg-white px-6 py-7 shadow-[0_18px_55px_rgba(0,0,0,0.08)] sm:px-8 sm:py-8"
        data-publication-access={view}
        lang={locale}
      >
        <div className="flex items-center justify-between gap-4 border-b border-black/[0.08] pb-5">
          <p className="font-mono text-xs font-medium tracking-[0.14em] text-[#676762]">
            {messages.eyebrow}
          </p>
          <AccessGlyph invalid={invalid} />
        </div>

        <div className="pt-7">
          <h1 className="text-[28px] font-medium leading-[1.15] tracking-[-0.035em]">
            {invalid ? messages.invalidTitle : messages.title}
          </h1>

          {hostname && !invalid ? (
            <p className="mt-3 w-fit max-w-full truncate border border-black/[0.09] bg-[#f7f7f5] px-2.5 py-1.5 font-mono text-xs text-[#555550]">
              {hostname}
            </p>
          ) : null}

          <div className="mt-5 text-sm leading-6 text-[#62625d]">
            {view === "signed-out" ? <p>{messages.signedOutBody}</p> : null}
            {view === "signed-in" && identity ? (
              <p className="font-medium text-[#30302d]">
                {messages.signedInAs.replace("{identity}", identity)}
              </p>
            ) : null}
            {view === "invalid" ? <p>{messages.invalidBody}</p> : null}
          </div>

          {view === "signed-out" && signInHref ? (
            <a
              className="mt-7 inline-flex min-h-11 w-full items-center justify-center bg-[#171717] px-4 py-2.5 text-sm font-medium text-white transition-colors hover:bg-[#30302d] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#171717]"
              href={signInHref}
            >
              {messages.signIn}
            </a>
          ) : null}

        </div>

        <p className="mt-7 border-t border-black/[0.08] pt-5 text-xs text-[#8a8a84]">
          {messages.footer}
        </p>
      </section>
    </main>
  );
}

function AccessGlyph({ invalid }: { readonly invalid: boolean }) {
  return (
    <span
      aria-hidden="true"
      className="grid size-9 shrink-0 place-items-center border border-black/[0.1] bg-[#f7f7f5] text-[#3c3c38]"
    >
      {invalid ? (
        <svg fill="none" height="17" viewBox="0 0 20 20" width="17">
          <path d="M10 6.25v4.25" stroke="currentColor" strokeLinecap="round" strokeWidth="1.5" />
          <path d="M10 13.75h.008" stroke="currentColor" strokeLinecap="round" strokeWidth="1.8" />
          <path d="M8.49 2.66 1.96 14.1A1.75 1.75 0 0 0 3.48 16.7h13.04a1.75 1.75 0 0 0 1.52-2.6L11.51 2.66a1.74 1.74 0 0 0-3.02 0Z" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.4" />
        </svg>
      ) : (
        <svg fill="none" height="17" viewBox="0 0 20 20" width="17">
          <rect height="9" rx="1.5" stroke="currentColor" strokeWidth="1.4" width="13" x="3.5" y="8" />
          <path d="M6.5 8V6a3.5 3.5 0 1 1 7 0v2" stroke="currentColor" strokeLinecap="round" strokeWidth="1.4" />
          <path d="M10 11.25v2.5" stroke="currentColor" strokeLinecap="round" strokeWidth="1.4" />
        </svg>
      )}
    </span>
  );
}
