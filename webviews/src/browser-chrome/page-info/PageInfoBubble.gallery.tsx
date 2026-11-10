// l10n-allow-file: gallery fixtures (sample sites), not shipped UI.
// The Page Info bubble over sample sites. The stage answers the bubble's commands the way the host
// does (a page move, a permission change), so every row can be clicked through.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { PageInfoCommand, PageInfoModel, SitePermissionState } from "./model";
import { PageInfoBubble, type PageInfoLook } from "./PageInfoBubble";

type Props = { model: PageInfoModel; look?: PageInfoLook };

const permissions: SitePermissionState[] = [
  { kind: "camera", setting: "allow", isDefault: false, isInUse: true },
  { kind: "microphone", setting: "allow", isDefault: false },
  { kind: "location", setting: "block", isDefault: false },
  { kind: "notifications", setting: "ask", isDefault: true },
  { kind: "sound", setting: "allow", isDefault: true },
];

const secure: PageInfoModel = {
  site: { kind: "web", connection: "secure", displayName: "meet.example.com" },
  page: { type: "main" },
  permissions,
  siteData: { firstPartyCookies: 14, siteCount: 3, thirdPartyPolicy: "allowed" },
  certificate: { valid: true, issuer: "Example Trust CA" },
  showsAboutThisPage: true,
};

const insecure: PageInfoModel = {
  site: { kind: "web", connection: "insecure", displayName: "intranet.example.test:8080" },
  page: { type: "main" },
  permissions: [{ kind: "popups", setting: "allow", isDefault: false }],
  siteData: null,
  certificate: null,
  needsReload: true,
};

const certificateError: PageInfoModel = {
  site: { kind: "web", connection: "certificateError", displayName: "expired.example.org" },
  page: { type: "security" },
  permissions: [],
  siteData: null,
  certificate: { valid: false },
  certificateFailure: "The certificate for this server expired 12 days ago.",
  certificateWarningsOff: true,
  certificateWarningScope: "profile",
};

function apply(model: PageInfoModel, command: PageInfoCommand): PageInfoModel {
  switch (command.type) {
    case "show":
      return { ...model, page: command.page };
    case "setPermission": {
      const rest = model.permissions.filter((state) => state.kind !== command.kind);
      const next = { kind: command.kind, setting: command.setting, isDefault: false };
      const at = model.permissions.findIndex((state) => state.kind === command.kind);
      const list =
        at < 0 ? [...rest, next] : model.permissions.map((state) => (state.kind === command.kind ? next : state));
      return { ...model, permissions: list, needsReload: true };
    }
    case "resetPermissions":
      return {
        ...model,
        permissions: model.permissions.map((state) => ({ ...state, isDefault: true })),
      };
    default:
      return model;
  }
}

function PageInfoFixture({ model, look }: Props) {
  const [state, setState] = useState(model);
  return (
    <div style={{ padding: 16 }}>
      <PageInfoBubble model={state} look={look} onCommand={(command) => setState((now) => apply(now, command))} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "browser-chrome.page-info",
  title: "Page Info bubble",
  area: "Browser chrome",
  experimental: true,
  height: 520,
  widths: { narrow: 360, normal: 420, wide: 520 },
  covers: ["browser-chrome/page-info/PageInfoBubble.tsx"],
  keywords: ["site information", "permissions", "certificate", "cookies", "omnibar chip"],
  load: async () => PageInfoFixture,
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "parity", label: "Parity" },
        { value: "grouped", label: "Grouped" },
        { value: "dense", label: "Dense" },
      ],
      defaultValue: "parity",
    },
  ],
  variants: {
    "main-secure": { props: { model: secure }, note: "Recommended look: today's native bubble." },
    "main-secure-grouped": {
      props: { model: secure, look: "grouped" },
      note: "Each group on its own inset card.",
    },
    "main-secure-dense": {
      props: { model: secure, look: "dense" },
      note: "One line per permission, state trailing.",
    },
    "main-insecure": {
      props: { model: insecure },
      note: "Plain http, a changed permission waiting for a reload.",
    },
    "main-long-host": {
      props: {
        model: {
          ...secure,
          site: { ...secure.site, displayName: "trusted.example.com.account-verification.attacker.test" },
        },
      },
      note: "A long host cuts its start: the real domain, attacker.test, stays visible.",
    },
    "main-long-label": {
      props: {
        model: {
          ...secure,
          site: {
            ...secure.site,
            displayName: "a-very-long-single-label-that-runs-the-full-sixty-three-characters.com:8443",
          },
        },
      },
      note: "One label wider than the header: its start is cut, the end and the port stay.",
    },
    "security-long-host": {
      props: {
        model: {
          ...secure,
          page: { type: "security" },
          site: { ...secure.site, displayName: "trusted.example.com.account-verification.attacker.test" },
        },
      },
    },
    "security-secure": { props: { model: { ...secure, page: { type: "security" } } } },
    "security-certificate-error": {
      props: { model: certificateError },
      note: "Danger ink, the engine's reason, and Turn on warnings for the whole profile.",
    },
    cookies: {
      props: {
        model: {
          ...secure,
          page: { type: "cookies" },
          siteData: { firstPartyCookies: 14, siteCount: 3, thirdPartyPolicy: "blocked" },
        },
      },
    },
    "cookies-loading": {
      props: { model: { ...secure, page: { type: "cookies" }, siteData: null } },
    },
    "permission-camera": {
      props: { model: { ...secure, page: { type: "permission", kind: "camera" } } },
    },
    "file-page": {
      props: {
        model: {
          site: { kind: "file", displayName: "/Users/me/Documents/report.html" },
          page: { type: "main" },
          permissions: [],
          siteData: null,
          certificate: null,
        },
      },
    },
  },
});
