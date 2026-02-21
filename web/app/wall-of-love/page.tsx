import type { Metadata } from "next";
import { SiteHeader } from "../components/site-header";

export const metadata: Metadata = {
  title: "Wall of Love — cmux",
  description:
    "What people are saying about cmux, the terminal built for multitasking.",
};

const testimonials = [
  {
    name: "Mitchell Hashimoto",
    handle: "@mitchellh",
    avatar:
      "https://pbs.twimg.com/profile_images/1141762999838842880/64_Y4_XB_400x400.jpg",
    text: "Another day another libghostty-based project, this time a macOS terminal with vertical tabs, better organization/notifications, embedded/scriptable browser specifically targeted towards people who use a ton of terminal-based agentic workflows.",
    url: "https://x.com/mitchellh/status/2024913161238053296",
    platform: "x" as const,
  },
  {
    name: "Oliver Kriška",
    handle: "@quatermain32",
    avatar:
      "https://pbs.twimg.com/profile_images/674992361974464512/ClmHiw_P_400x400.jpg",
    text: "I have used it for whole day and it's really great. Some bugs like opening file in integrated agent browser (yes, it has browser) but other than that it's good.",
    url: "https://x.com/quatermain32/status/2024919743484891629",
    platform: "x" as const,
  },
  {
    name: "johnthedebs",
    handle: "johnthedebs",
    avatar: null,
    text: "Hey, this looks seriously awesome. Love the ideas here, specifically: the programmability, layered UI, browser w/ api. Looking forward to giving this a spin. Also want to add that I really appreciate Mitchell Hashimoto creating libghostty; it feels like an exciting time to be a terminal user.",
    url: "https://news.ycombinator.com/item?id=47079718",
    platform: "hn" as const,
  },
  {
    name: "Joe Riddle",
    handle: "@joeriddles10",
    avatar:
      "https://pbs.twimg.com/profile_images/1466920091707076608/pxfGMeC0_400x400.jpg",
    text: "Vertical tabs in my terminal \u{1F924} I never thought of that before. I use and love Firefox vertical tabs.",
    url: "https://x.com/joeriddles10/status/2024914132416561465",
    platform: "x" as const,
  },
  {
    name: "Marc",
    handle: "@prodigy00",
    avatar:
      "https://pbs.twimg.com/profile_images/1726697382337724417/AGafbkp1_400x400.jpg",
    text: "This is niceeeeee!",
    url: "https://x.com/prodigy00/status/2024946851401613399",
    platform: "x" as const,
  },
  {
    name: "dchu17",
    handle: "dchu17",
    avatar: null,
    text: "Gave this a run and it was pretty intuitive. Good work!",
    url: "https://news.ycombinator.com/item?id=47082577",
    platform: "hn" as const,
  },
];

function PlatformIcon({ platform }: { platform: "x" | "hn" }) {
  if (platform === "x") {
    return (
      <svg
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="currentColor"
        className="text-muted"
      >
        <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
      </svg>
    );
  }
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="currentColor"
      className="text-muted"
    >
      <path d="M0 24V0h24v24H0zM6.951 5.896l4.112 7.708-4.311 4.612h1.162l3.727-3.989 3.01 3.989h3.957l-4.34-8.139 4.009-4.29h-1.163l-3.424 3.664L10.91 5.896H6.951zm1.627.858h1.816l7.028 10.493h-1.816L8.578 6.754z" />
    </svg>
  );
}

function Initials({ name }: { name: string }) {
  const initials = name
    .split(/[\s_-]+/)
    .map((w) => w[0])
    .join("")
    .toUpperCase()
    .slice(0, 2);
  return (
    <div className="w-10 h-10 rounded-full bg-code-bg border border-border flex items-center justify-center text-xs font-medium text-muted shrink-0">
      {initials}
    </div>
  );
}

function TestimonialCard({
  testimonial,
}: {
  testimonial: (typeof testimonials)[number];
}) {
  return (
    <a
      href={testimonial.url}
      target="_blank"
      rel="noopener noreferrer"
      className="group block rounded-xl border border-border p-5 hover:bg-code-bg transition-colors break-inside-avoid mb-4"
    >
      <div className="flex items-center gap-3 mb-3">
        {testimonial.avatar ? (
          <img
            src={testimonial.avatar}
            alt={testimonial.name}
            width={40}
            height={40}
            className="rounded-full shrink-0"
          />
        ) : (
          <Initials name={testimonial.name} />
        )}
        <div className="min-w-0 flex-1">
          <div className="font-medium text-sm truncate">
            {testimonial.name}
          </div>
          <div className="text-xs text-muted truncate">
            {testimonial.handle}
          </div>
        </div>
        <PlatformIcon platform={testimonial.platform} />
      </div>
      <p className="text-[15px] leading-relaxed text-muted group-hover:text-foreground transition-colors">
        {testimonial.text}
      </p>
    </a>
  );
}

export default function WallOfLovePage() {
  return (
    <div className="min-h-screen">
      <SiteHeader section="wall of love" />
      <main className="w-full max-w-6xl mx-auto px-6 py-10">
        <h1 className="text-2xl font-semibold tracking-tight mb-2">
          Wall of Love
        </h1>
        <p className="text-muted text-[15px] mb-8">
          What people are saying about cmux.
        </p>

        <div className="columns-1 sm:columns-2 lg:columns-3 gap-4">
          {testimonials.map((t) => (
            <TestimonialCard key={t.url} testimonial={t} />
          ))}
        </div>
      </main>
    </div>
  );
}
