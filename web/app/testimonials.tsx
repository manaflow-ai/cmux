export const testimonials = [
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
    name: "dchu17",
    handle: "dchu17",
    avatar: null,
    text: "Gave this a run and it was pretty intuitive. Good work!",
    url: "https://news.ycombinator.com/item?id=47082577",
    platform: "hn" as const,
  },
];

export type Testimonial = (typeof testimonials)[number];

export function PlatformIcon({ platform }: { platform: "x" | "hn" }) {
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
      viewBox="0 0 256 256"
      className="text-muted"
    >
      <rect width="256" height="256" rx="28" fill="#ff6600" />
      <text
        x="128"
        y="188"
        fontSize="180"
        fontWeight="bold"
        fontFamily="sans-serif"
        fill="white"
        textAnchor="middle"
      >
        Y
      </text>
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

export function TestimonialCard({
  testimonial,
}: {
  testimonial: Testimonial;
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
