export const testimonials = [
  {
    name: "Mitchell Hashimoto",
    handle: "@mitchellh",
    subtitle: "Creator of Ghostty and founder of HashiCorp",
    avatar: "/avatars/mitchellh.jpg",
    text: "Another day another libghostty-based project, this time a macOS terminal with vertical tabs, better organization/notifications, embedded/scriptable browser specifically targeted towards people who use a ton of terminal-based agentic workflows.",
    url: "https://x.com/mitchellh/status/2024913161238053296",
    platform: "x" as const,
  },
  {
    name: "Nick Schrock",
    handle: "@schrockn",
    subtitle: "Creator of Dagster. GraphQL co-creator.",
    avatar: "/avatars/schrockn.jpg",
    text: "This is exactly the product I've been looking for. After two hours this am I've in love.",
    url: "https://x.com/schrockn/status/2025182278637207857",
    platform: "x" as const,
  },
  {
    name: "Edward Grefenstette",
    handle: "@egrefen",
    subtitle: "Director of Research at Google DeepMind",
    avatar: "/avatars/egrefen.jpg",
    text: "I've been using this all weekend and it's amazing.",
    url: "https://x.com/egrefen/status/2026806171563184199",
    platform: "x" as const,
  },
  {
    name: "あさざ",
    handle: "@asaza_0928",
    avatar: "/avatars/asaza_0928.jpg",
    text: "cmux 良さそうすぎてついにバイバイ VSCode するときなのかもしれない",
    translation: "cmux looks so good it might finally be time to say goodbye to VSCode",
    url: "https://x.com/asaza_0928/status/2026057269075698015",
    platform: "x" as const,
  },
  {
    name: "johnthedebs",
    handle: "johnthedebs",
    avatar: null,
    text: "Hey, this looks seriously awesome. Love the ideas here, specifically: the programmability, layered UI, browser w/ api. Looking forward to giving this a spin. Also want to add that I really appreciate Mitchell Hashimoto creating libghostty; it feels like an exciting time to be a terminal user.",
    url: "https://news.ycombinator.com/item?id=47083596",
    platform: "hn" as const,
  },
  {
    name: "Joe Riddle",
    handle: "@joeriddles10",
    avatar: "/avatars/joeriddles10.jpg",
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
  {
    name: "afruth",
    handle: "u/afruth",
    avatar: null,
    text: "I like it, ran it in the past day on three parallel projects each with several worktrees. Having this paired with lazygit and yazi / nvim made me a bit more productive than usual without having to chase multiple ghostty / iTerm instances. Also feels more natural than tmux.",
    url: "https://www.reddit.com/r/ClaudeCode/comments/1r9g45u/comment/o6sxbr3/",
    platform: "reddit" as const,
  },
  {
    name: "Norihiro Narayama",
    handle: "@northprint",
    avatar: "/avatars/northprint.jpg",
    text: "cmux良さそうなので入れてみたけれど、良い",
    translation: "Tried cmux since it looked good — it's good",
    url: "https://x.com/northprint/status/2025740286677434581",
    platform: "x" as const,
  },
  {
    name: "Kishore Neelamegam",
    handle: "@indykish",
    avatar: "/avatars/indykish.jpg",
    text: "cmux is pretty good.",
    url: "https://x.com/indykish/status/2025318347970412673",
    platform: "x" as const,
  },
  {
    name: "かたりん",
    handle: "@kataring",
    avatar: "/avatars/kataring.jpg",
    text: "cmux.dev に乗り換えた",
    translation: "Switched to cmux.dev",
    url: "https://x.com/kataring/status/2026189035056832718",
    platform: "x" as const,
  },
  {
    name: "Scott Watermasysk",
    handle: "@scottw",
    avatar: "/avatars/scottw.jpg",
    text: "This has been such a useful find. I can't recommend it enough.",
    url: "https://x.com/scottw/status/2026806893067551084",
    platform: "x" as const,
  },
  {
    name: "John Blythe",
    handle: "@johnblythe",
    avatar: "/avatars/johnblythe.jpg",
    text: "grabbed this over the weekend and loved it. been waiting for something like this.",
    url: "https://x.com/johnblythe/status/2026812731844637010",
    platform: "x" as const,
  },
  {
    name: "Christopher",
    handle: "@BChris91",
    avatar: "/avatars/bchris91.jpg",
    text: "This is exactly what I've wanted. Amazing job thank you!",
    url: "https://x.com/BChris91/status/2026821091637838273",
    platform: "x" as const,
  },
];

export type Testimonial = (typeof testimonials)[number];

export function PlatformIcon({ platform }: { platform: "x" | "hn" | "reddit" }) {
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
  if (platform === "reddit") {
    return (
      <svg
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="#FF4500"
        className="text-muted"
      >
        <path d="M12 0C5.373 0 0 5.373 0 12s5.373 12 12 12 12-5.373 12-12S18.627 0 12 0zm6.066 13.71c.147.307.222.644.222.994 0 1.987-2.752 3.596-6.148 3.596s-6.148-1.61-6.148-3.596c0-.35.075-.687.222-.994a1.426 1.426 0 01-.468-1.068c0-.798.648-1.446 1.446-1.446.39 0 .744.155 1.003.408 1.018-.67 2.396-1.09 3.917-1.148l.734-3.296a.348.348 0 01.416-.268l2.39.53a1.05 1.05 0 011.976.49c0 .58-.47 1.05-1.05 1.05a1.05 1.05 0 01-1.04-1.18l-2.07-.46-.625 2.81c1.465.076 2.786.493 3.768 1.14a1.44 1.44 0 011.003-.408c.798 0 1.446.648 1.446 1.446 0 .416-.176.79-.468 1.054zM9.06 12.61c-.58 0-1.05.47-1.05 1.05s.47 1.05 1.05 1.05 1.05-.47 1.05-1.05-.47-1.05-1.05-1.05zm5.88 0c-.58 0-1.05.47-1.05 1.05s.47 1.05 1.05 1.05 1.05-.47 1.05-1.05-.47-1.05-1.05-1.05zm-5.04 3.48c-.1-.1-.1-.26 0-.36.1-.1.26-.1.36 0 .58.58 1.39.87 2.19.87s1.61-.29 2.19-.87c.1-.1.26-.1.36 0 .1.1.1.26 0 .36-.68.68-1.59 1.05-2.55 1.05s-1.87-.37-2.55-1.05z" />
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
          {"subtitle" in testimonial && testimonial.subtitle && (
            <div className="text-xs text-muted truncate">
              {testimonial.subtitle}
            </div>
          )}
          <div className="text-xs text-muted truncate">
            {testimonial.handle}
          </div>
        </div>
        <PlatformIcon platform={testimonial.platform} />
      </div>
      <p className="text-[15px] leading-relaxed text-muted group-hover:text-foreground transition-colors">
        {testimonial.text}
      </p>
      {"translation" in testimonial && testimonial.translation && (
        <p className="text-xs text-muted/60 mt-1.5 italic">
          {testimonial.translation}
        </p>
      )}
    </a>
  );
}
