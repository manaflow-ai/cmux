// In-app campaign catalog served by /api/campaigns.
//
// A campaign is a server-authored in-app message (inline banner, sheet, or
// full-screen takeover) rendered natively by the mobile app. Clients evaluate
// targeting locally (platform, app-version range, date window, rollout
// percent) and skip entries they cannot render (unknown template or newer
// schemaVersion), so adding templates later is backward compatible.
//
// Authoring rules (enforced by web/app/api/campaigns/route.ts at module load
// and by web/tests/campaigns-route.test.ts in CI):
//   - ids are unique kebab-case slugs and are never reused; dismissal state
//     on devices is keyed by id
//   - every user-visible string carries BOTH en and ja
//   - image URLs are https or site-relative under /campaigns/ (file must
//     exist in web/public/campaigns/); clients resolve relative URLs against
//     their API base URL
//   - button URLs are https; at most 2 buttons
//   - the iosCampaigns flag registered in web/app/lib/feature-flags.ts is
//     the global kill switch checked by clients before showing anything

export interface CampaignText {
  en: string;
  ja: string;
}

export interface CampaignImage {
  /** https URL or site-relative path under /campaigns/. */
  light: string;
  /** Optional dark-mode variant; falls back to light. */
  dark?: string;
  /** Width / height, used to reserve layout before the image loads. */
  aspectRatio?: number;
  alt?: CampaignText;
}

export type CampaignButtonAction =
  | { type: "openURL"; url: string }
  | { type: "dismiss" };

export interface CampaignButton {
  label: CampaignText;
  action: CampaignButtonAction;
  /** primary renders prominent; secondary renders plain. Default primary. */
  role?: "primary" | "secondary";
}

export type CampaignTemplate = "banner" | "sheet" | "fullscreen";
export type CampaignPlatform = "ios" | "macos";
export type CampaignReshowPolicy = "once" | "oncePerVersion" | "untilDismissed";

export interface Campaign {
  id: string;
  template: CampaignTemplate;
  platforms: CampaignPlatform[];
  /** Inclusive marketing-version bounds (e.g. "1.0.5"); omit for no bound. */
  minAppVersion?: string;
  maxAppVersion?: string;
  /** ISO-8601 instants; omit for always-on. */
  startsAt?: string;
  endsAt?: string;
  /** 0-100; deterministic per-install rollout. Default 100. */
  rolloutPercent?: number;
  /** Higher shows first when several campaigns are eligible. Default 0. */
  priority?: number;
  reshowPolicy: CampaignReshowPolicy;
  /** Listed in the in-app What's New screen after dismissal. */
  showInWhatsNew?: boolean;
  title: CampaignText;
  body: CampaignText;
  image?: CampaignImage;
  /** Accent for buttons/highlights, "#RRGGBB". */
  accentColor?: string;
  buttons?: CampaignButton[];
}

export interface CampaignCatalog {
  schemaVersion: 1;
  updatedAt: string;
  campaigns: Campaign[];
}

export const campaignCatalog: CampaignCatalog = {
  schemaVersion: 1,
  updatedAt: "2026-08-21T00:00:00.000Z",
  // Each campaign lands as its own reviewed PR. The launch campaign below
  // doubles as the dogfood fixture for the campaign system itself; drop it
  // here (and its images) to retire it.
  campaigns: [
    {
      id: "ios-campaigns-hello",
      template: "sheet",
      platforms: ["ios"],
      startsAt: "2026-08-20T00:00:00.000Z",
      endsAt: "2026-10-01T00:00:00.000Z",
      reshowPolicy: "once",
      showInWhatsNew: true,
      title: {
        en: "Announcements, right here",
        ja: "お知らせをアプリ内でお届け",
      },
      body: {
        en: "cmux can now let you know about new features, fixes, and offers inside the app. Anything you miss stays in Settings under What's New.",
        ja: "cmux の新機能・修正・キャンペーンをアプリ内でお知らせできるようになりました。見逃したお知らせは設定の「新着情報」からいつでも確認できます。",
      },
      image: {
        light: "/campaigns/ios-campaigns-hello.png",
        dark: "/campaigns/ios-campaigns-hello-dark.png",
        aspectRatio: 1,
      },
      buttons: [
        {
          label: { en: "See the changelog", ja: "変更履歴を見る" },
          action: { type: "openURL", url: "https://cmux.com/docs/changelog" },
        },
        {
          label: { en: "Done", ja: "閉じる" },
          action: { type: "dismiss" },
          role: "secondary",
        },
      ],
    },
  ],
};
