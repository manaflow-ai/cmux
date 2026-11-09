// The Page Info bubble (the omnibar chip's site-information popup): the web twin of the native
// PageInfoPages / PageInfoRowView / PageInfoHeaderView, at the Standard density's metrics
// (pageInfo.css). It only draws the model and sends `PageInfoCommand`s; the host owns the state,
// the anchor and closing on an outside click. Arrow keys move between rows, Escape closes, and the
// leading arrow (Left, Right in RTL) goes back from a subpage, as the native panel's key handler does.
import type { KeyboardEvent, ReactNode } from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import type { Strings } from "../../pages/shared/i18n";
import { Switch } from "../../ui/Switch";
import "../../ui/popupSurface.css";
import {
  choices,
  connectionIcon,
  defaultSetting,
  enabledSetting,
  identityIcon,
  isDanger,
  isOn,
  permissionIcon,
  resettableCount,
  splitSiteName,
  type PageInfoCommand,
  type PageInfoConnection,
  type PageInfoModel,
  type PageInfoSiteKind,
  type SitePermissionKind,
  type SitePermissionState,
} from "./model";
import { pageInfoStrings } from "./strings";
import { choiceTitle, permissionName } from "./words";
import "./pageInfo.css";

/**
 * - `parity`: today's native bubble (rows on one card, hairlines between groups).
 * - `grouped`: each group on its own inset card, no hairlines.
 * - `dense`: one-line permission rows with the state trailing, so more fit before scrolling.
 */
export type PageInfoLook = "parity" | "grouped" | "dense";

export type PageInfoBubbleProps = {
  model: PageInfoModel;
  onCommand: (command: PageInfoCommand) => void;
  look?: PageInfoLook;
  strings?: Strings;
  /** Draws its own glass card. Off in the app, where the native panel's card is the glass. */
  glass?: boolean;
};

type Accessory = "chevron" | "external" | { toggle: boolean; onToggle: (on: boolean) => void };

type RowProps = {
  icon?: string;
  title: string;
  subtitle?: string;
  accessory?: Accessory;
  danger?: boolean;
  onActivate?: () => void;
  /** A radio choice of the permission subpage. */
  checked?: boolean;
  tooltip?: string;
  id: string;
};

const FOCUSABLE = "[data-pi-focus]";

function Row({ icon, title, subtitle, accessory, danger, onActivate, checked, tooltip, id }: RowProps) {
  const toggle = typeof accessory === "object" ? accessory : undefined;
  const body = (
    <>
      <span className="pi-row-icon">{icon && <Icon name={icon} size={16} row />}</span>
      <span className="pi-row-text">
        <span className="pi-row-title">{title}</span>
        {subtitle && <span className="pi-row-subtitle">{subtitle}</span>}
      </span>
      {accessory === "chevron" && <Icon name="disclosure.collapsed" size={14} row className="pi-row-mark" />}
      {accessory === "external" && <Icon name="link.open.newtab" size={14} row className="pi-row-mark" />}
    </>
  );
  const flags = {
    "data-danger": danger || undefined,
    "data-subtitle": subtitle ? true : undefined,
  };
  if (toggle) {
    // A row with a toggle: the row opens the permission's page, the switch flips it. A row with
    // no page to open (the permission's own page) flips it too.
    const activate = onActivate ?? (() => toggle.onToggle(!toggle.toggle));
    return (
      <div className="pi-row" data-row-id={id} {...flags}>
        <button type="button" className="pi-row-main" data-pi-focus onClick={activate}>
          {body}
        </button>
        <Switch
          size="sm"
          className="pi-switch"
          aria-label={title}
          checked={toggle.toggle}
          onCheckedChange={(on) => toggle.onToggle(on)}
        />
      </div>
    );
  }
  if (!onActivate) {
    return (
      <div className="pi-row" data-static data-row-id={id} {...flags}>
        {body}
      </div>
    );
  }
  return (
    <button
      type="button"
      className="pi-row pi-row-main"
      data-pi-focus
      data-row-id={id}
      role={checked === undefined ? undefined : "radio"}
      aria-checked={checked}
      title={tooltip}
      onClick={onActivate}
      {...flags}
    >
      {body}
    </button>
  );
}

function Header({
  title,
  subtitle,
  back,
  strings,
  send,
}: {
  title: ReactNode;
  subtitle?: ReactNode;
  back: boolean;
  strings: Strings;
  send: (command: PageInfoCommand) => void;
}) {
  return (
    <div className="pi-header" data-back={back || undefined}>
      {back && (
        <button
          type="button"
          className="pi-icon-button"
          data-pi-focus
          aria-label={strings.t("pageInfo.back")}
          onClick={() => send({ type: "show", page: { type: "main" } })}
        >
          <Icon name="nav.back" size={14} row />
        </button>
      )}
      <span className="pi-header-text">
        <span className="pi-header-title">{title}</span>
        {subtitle && <span className="pi-header-subtitle">{subtitle}</span>}
      </span>
      <button
        type="button"
        className="pi-icon-button"
        data-pi-focus
        aria-label={strings.t("pageInfo.close")}
        onClick={() => send({ type: "close" })}
      >
        <Icon name="action.close" size={14} row />
      </button>
    </div>
  );
}

/**
 * The site's name, cut in the middle when it is too long: the end (its registrable domain and
 * port) always shows, so a long host cannot hide the real site behind a trusted-looking prefix.
 */
function SiteName({ name }: { name: string }) {
  const [head, tail] = splitSiteName(name);
  return (
    <span className="pi-site-name" title={name}>
      <span className="pi-site-name-head">{head}</span>
      <span className="pi-site-name-tail">
        <bdi dir="ltr">{tail}</bdi>
      </span>
    </span>
  );
}

const Note = ({ children }: { children: ReactNode }) => <p className="pi-note">{children}</p>;
const Section = ({ children }: { children: ReactNode }) => <div className="pi-section">{children}</div>;

// MARK: Words (PageInfoStrings, PageInfoModel.stateText / choiceTitle)

const NO_ASK_TEXT = new Set<SitePermissionKind>([
  "javascript",
  "images",
  "popups",
  "sound",
  "sensors",
  "backgroundSync",
  "thirdPartySignIn",
  "insecureContent",
]);

export function stateText(strings: Strings, state: SitePermissionState): string {
  const t = strings.t;
  if (state.isInUse) return t("pageInfo.state.usingNow");
  if (state.kind === "sound" && state.setting === "allow")
    return t(state.isDefault ? "pageInfo.state.automaticDefault" : "pageInfo.state.allowed");
  if (state.kind === "sound" && state.setting === "block") return t("pageInfo.state.muted");
  switch (state.setting) {
    case "allow":
      return t(state.isDefault ? "pageInfo.state.allowedDefault" : "pageInfo.state.allowed");
    case "block":
      return t(state.isDefault ? "pageInfo.state.notAllowedDefault" : "pageInfo.state.notAllowed");
    case "ask":
      return NO_ASK_TEXT.has(state.kind) ? t("pageInfo.choice.ask") : t(`pageInfo.ask.${state.kind}`);
  }
}

function shortSummary(strings: Strings, connection: PageInfoConnection, long: boolean): string {
  switch (connection) {
    case "secure":
      return strings.t("pageInfo.security.secure");
    case "insecure":
    case "certificateError":
      return strings.t(long ? "pageInfo.security.notSecureLong" : "pageInfo.security.notSecure");
    case "mixedContent":
      return strings.t(long ? "pageInfo.security.mixedLong" : "pageInfo.security.mixed");
    case "dangerous":
      return strings.t("pageInfo.security.dangerous");
  }
}

function details(strings: Strings, connection: PageInfoConnection): string {
  switch (connection) {
    case "secure":
      return strings.t("pageInfo.security.secureDetails");
    case "insecure":
    case "certificateError":
      return strings.t("pageInfo.security.notSecureDetails");
    case "mixedContent":
      return strings.t("pageInfo.security.mixedDetails");
    case "dangerous":
      return strings.t("pageInfo.security.dangerousDetails");
  }
}

const IDENTITY_KEYS: Record<PageInfoSiteKind, string> = {
  file: "pageInfo.identity.file",
  extensionPage: "pageInfo.identity.extension",
  viewSource: "pageInfo.identity.viewSource",
  devTools: "pageInfo.identity.devTools",
  internalPage: "pageInfo.identity.internal",
  web: "pageInfo.identity.internal",
};

// MARK: Pages

type PageProps = {
  model: PageInfoModel;
  strings: Strings;
  send: (command: PageInfoCommand) => void;
};

function MainPage({ model, strings, send }: PageProps) {
  const { site } = model;
  const t = strings.t;
  const header = <Header title={<SiteName name={site.displayName} />} back={false} strings={strings} send={send} />;
  if (site.kind !== "web" || !site.connection) {
    return (
      <>
        {header}
        <Section>
          <Row id="pageInfo.identity" icon={identityIcon(site.kind)} title={t(IDENTITY_KEYS[site.kind])} />
        </Section>
      </>
    );
  }
  const connection = site.connection;
  const resettable = resettableCount(model.permissions);
  return (
    <>
      {header}
      <Section>
        <Row
          id="pageInfo.security"
          icon={connectionIcon(connection)}
          title={shortSummary(strings, connection, false)}
          accessory="chevron"
          danger={isDanger(connection)}
          onActivate={() => send({ type: "show", page: { type: "security" } })}
        />
      </Section>
      {(model.permissions.length > 0 || model.needsReload) && (
        <Section>
          {model.permissions.map((state) => (
            <Row
              key={state.kind}
              id={`pageInfo.permission.${state.kind}`}
              icon={permissionIcon(state.kind, state.setting === "block")}
              title={permissionName(strings, state.kind)}
              subtitle={stateText(strings, state)}
              accessory={{
                toggle: isOn(state),
                onToggle: (on) =>
                  send({
                    type: "setPermission",
                    kind: state.kind,
                    setting: on ? enabledSetting(state.kind) : "block",
                  }),
              }}
              onActivate={() => send({ type: "show", page: { type: "permission", kind: state.kind } })}
            />
          ))}
          {resettable > 0 && (
            <Row
              id="pageInfo.reset"
              icon="action.reset"
              title={t(resettable === 1 ? "pageInfo.reset.one" : "pageInfo.reset.many")}
              onActivate={() => send({ type: "resetPermissions" })}
            />
          )}
          {model.needsReload && (
            <>
              <Note>{t("pageInfo.reload.text")}</Note>
              <Row
                id="pageInfo.reload"
                icon="action.reload"
                title={t("pageInfo.reload.button")}
                onActivate={() => send({ type: "reload" })}
              />
            </>
          )}
        </Section>
      )}
      <Section>
        <Row
          id="pageInfo.cookies"
          icon="data.storage"
          title={t("pageInfo.cookies.header")}
          accessory="chevron"
          onActivate={() => send({ type: "show", page: { type: "cookies" } })}
        />
        <Row
          id="pageInfo.siteSettings"
          icon="settings"
          title={t("pageInfo.siteSettings")}
          accessory="external"
          onActivate={() => send({ type: "siteSettings" })}
        />
        {model.showsAboutThisPage && (
          <Row
            id="pageInfo.about"
            icon="action.review"
            title={t("pageInfo.about.title")}
            subtitle={t("pageInfo.about.description")}
            accessory="external"
            onActivate={() => send({ type: "aboutThisPage" })}
          />
        )}
      </Section>
    </>
  );
}

function SecurityPage({ model, strings, send }: PageProps) {
  const { site, certificate } = model;
  const t = strings.t;
  const connection = site.connection;
  const header = (
    <Header
      title={t("pageInfo.security.header")}
      subtitle={<SiteName name={site.displayName} />}
      back
      strings={strings}
      send={send}
    />
  );
  if (!connection) return header;
  const paragraphs = [details(strings, connection)];
  if (connection === "certificateError") {
    paragraphs.unshift(t("pageInfo.security.identityNotVerified"));
    if (model.certificateFailure) paragraphs.push(model.certificateFailure);
  }
  return (
    <>
      {header}
      <Section>
        <Row
          id="pageInfo.securitySummary"
          icon={connectionIcon(connection)}
          title={shortSummary(strings, connection, true)}
          danger={isDanger(connection)}
        />
        {paragraphs.map((text) => (
          <Note key={text}>{text}</Note>
        ))}
      </Section>
      {model.certificateWarningsOff && (
        <Section>
          <Note>{t("pageInfo.security.warningsTurnedOff")}</Note>
          <Row
            id="pageInfo.turnOnWarnings"
            icon="site.permission.insecurecontent.blocked"
            title={t("pageInfo.security.turnOnWarnings")}
            subtitle={
              model.certificateWarningScope === "profile" ? t("pageInfo.security.turnOnWarnings.allSites") : undefined
            }
            onActivate={() => send({ type: "reenableCertificateWarnings" })}
          />
        </Section>
      )}
      {certificate && (
        <Section>
          <Row
            id="pageInfo.certificate"
            icon={certificate.valid ? "trust.verified" : "trust.invalid"}
            title={t(certificate.valid ? "pageInfo.certificate.valid" : "pageInfo.certificate.invalid")}
            accessory="external"
            danger={!certificate.valid}
            tooltip={
              certificate.valid && certificate.issuer
                ? strings.format("pageInfo.certificate.showIssuedBy", certificate.issuer)
                : t("pageInfo.certificate.show")
            }
            onActivate={() => send({ type: "showCertificate" })}
          />
        </Section>
      )}
    </>
  );
}

function CookiesPage({ model, strings, send }: PageProps) {
  const t = strings.t;
  const data = model.siteData;
  return (
    <>
      <Header
        title={t("pageInfo.cookies.header")}
        subtitle={<SiteName name={model.site.displayName} />}
        back
        strings={strings}
        send={send}
      />
      <Section>
        <Note>{t("pageInfo.cookies.description")}</Note>
        {!data && <Row id="pageInfo.loading" title={t("pageInfo.loading")} />}
        {data?.thirdPartyPolicy === "blocked" && (
          <Row
            id="pageInfo.thirdParty"
            icon="action.hide"
            title={t("pageInfo.cookies.thirdParty")}
            subtitle={t("pageInfo.cookies.thirdPartyBlocked")}
          />
        )}
        {data && (
          <Row
            id="pageInfo.manageSiteData"
            icon="inbox"
            title={t("pageInfo.cookies.manage")}
            subtitle={[
              strings.format("pageInfo.cookies.count", String(data.firstPartyCookies)),
              strings.format("pageInfo.cookies.sites", String(data.siteCount)),
            ].join(" · ")}
            accessory="external"
            onActivate={() => send({ type: "manageSiteData" })}
          />
        )}
      </Section>
    </>
  );
}

function PermissionPage({ model, strings, send, kind }: PageProps & { kind: SitePermissionKind }) {
  const name = permissionName(strings, kind);
  const state = model.permissions.find((entry) => entry.kind === kind) ?? {
    kind,
    setting: defaultSetting(kind),
    isDefault: true,
  };
  return (
    <>
      <Header title={name} subtitle={<SiteName name={model.site.displayName} />} back strings={strings} send={send} />
      <Section>
        <Row
          id="pageInfo.permissionToggle"
          icon={permissionIcon(kind, state.setting === "block")}
          title={name}
          subtitle={stateText(strings, state)}
          accessory={{
            toggle: isOn(state),
            onToggle: (on) => send({ type: "setPermission", kind, setting: on ? enabledSetting(kind) : "block" }),
          }}
        />
      </Section>
      <Section>
        <div role="radiogroup" aria-label={name} className="pi-choices">
          {choices(kind).map((choice) => (
            <Row
              key={choice}
              id={`pageInfo.choice.${choice}`}
              icon={choice === state.setting ? "state.selected" : "icon.clear"}
              title={choiceTitle(strings, choice, kind)}
              checked={choice === state.setting}
              onActivate={() => send({ type: "setPermission", kind, setting: choice })}
            />
          ))}
        </div>
      </Section>
      <Section>
        <Row
          id="pageInfo.manage"
          icon="settings"
          title={strings.t("pageInfo.permission.manage")}
          accessory="external"
          onActivate={() => send({ type: "siteSettings" })}
        />
      </Section>
    </>
  );
}

export function PageInfoBubble({
  model,
  onCommand,
  look = "parity",
  strings = pageInfoStrings(),
  glass = true,
}: PageInfoBubbleProps) {
  const page = model.page;
  const props = { model, strings, send: onCommand };
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    const root = event.currentTarget;
    const back = getComputedStyle(root).direction === "rtl" ? "ArrowRight" : "ArrowLeft";
    if (event.key === "Escape") {
      event.preventDefault();
      onCommand({ type: "close" });
    } else if (event.key === back && page.type !== "main") {
      event.preventDefault();
      onCommand({ type: "show", page: { type: "main" } });
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const items = [...root.querySelectorAll<HTMLElement>(FOCUSABLE)];
      // Arrows move row by row: a row's switch (Tab reaches it) counts as its row.
      const active = document.activeElement as HTMLElement | null;
      const row = active?.closest(".pi-row")?.querySelector<HTMLElement>(FOCUSABLE) ?? active;
      const at = row ? items.indexOf(row) : -1;
      const step = event.key === "ArrowDown" ? 1 : -1;
      const next = at < 0 ? (step > 0 ? 0 : items.length - 1) : (at + step + items.length) % items.length;
      items[next]?.focus();
    }
  };
  return (
    // The host's popup window is the dialog; this is its card. Its keys move between rows, go back and close.
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions, jsx-a11y/no-noninteractive-tabindex
    <section
      className={glass ? "pi-bubble ui-popup ui-glass" : "pi-bubble"}
      data-look={look}
      data-page={page.type}
      aria-label={model.site.displayName}
      tabIndex={-1}
      onKeyDown={onKeyDown}
      data-gallery-track
    >
      {page.type === "main" && <MainPage {...props} />}
      {page.type === "security" && <SecurityPage {...props} />}
      {page.type === "cookies" && <CookiesPage {...props} />}
      {page.type === "permission" && <PermissionPage {...props} kind={page.kind} />}
    </section>
  );
}
