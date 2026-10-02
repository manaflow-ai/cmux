import type { Metadata } from "next";
import {
  acceptOrigin,
  forwardUrl,
  INVITE_DESCRIPTION,
  INVITE_IMAGE,
  INVITE_TITLE,
  isInviteCode,
} from "../invite-link";
import { InviteForward } from "./invite-forward";

type InvitePageProps = { params: Promise<{ code: string }> };

export async function generateMetadata({ params }: InvitePageProps): Promise<Metadata> {
  const { code } = await params;
  const url = `https://cmux.com/i/${isInviteCode(code) ? code : ""}`;
  return {
    title: INVITE_TITLE,
    description: INVITE_DESCRIPTION,
    robots: { index: false, follow: false },
    referrer: "no-referrer",
    openGraph: {
      type: "website",
      siteName: "cmux",
      title: INVITE_TITLE,
      description: INVITE_DESCRIPTION,
      url,
      images: [{ url: INVITE_IMAGE, width: 2400, height: 1260, alt: "cmux" }],
    },
    twitter: {
      card: "summary_large_image",
      title: INVITE_TITLE,
      description: INVITE_DESCRIPTION,
      images: [INVITE_IMAGE],
    },
  };
}

export default async function InvitePage({ params }: InvitePageProps) {
  const { code } = await params;
  const origin = acceptOrigin();
  const target = forwardUrl(origin, code, "");
  return (
    <main className="flex min-h-screen items-center justify-center bg-black px-6 text-white">
      <section className="w-full max-w-sm text-center">
        {target ? (
          <>
            <h1 className="text-2xl font-medium tracking-tight">{INVITE_TITLE}</h1>
            <p className="mt-3 text-sm leading-6 text-neutral-400">
              cmux is where people and their AI agents work together.
            </p>
            <InviteForward origin={origin} code={code} />
            <a
              className="mt-8 block rounded-xl bg-white px-4 py-3 text-sm font-semibold text-black"
              href={target}
            >
              Open the invite
            </a>
          </>
        ) : (
          <>
            <h1 className="text-2xl font-medium tracking-tight">This invite link is incomplete</h1>
            <p className="mt-3 text-sm leading-6 text-neutral-400">
              Open the full link from the message you received, or ask the sender for a new one.
            </p>
          </>
        )}
      </section>
    </main>
  );
}
