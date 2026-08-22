import { createHash } from "node:crypto";

import {
  campaignCatalog,
  type Campaign,
  type CampaignButton,
  type CampaignCatalog,
  type CampaignImage,
  type CampaignText,
} from "../../../data/campaigns";

const CACHE_CONTROL = "public, s-maxage=300, stale-while-revalidate=86400";
const ALLOW_METHODS = "GET, OPTIONS";
const ALLOW_HEADERS = "If-None-Match, Content-Type";
const TEMPLATES = new Set(["banner", "sheet", "fullscreen"]);
const PLATFORMS = new Set(["ios", "macos"]);
const RESHOW_POLICIES = new Set(["once", "oncePerVersion", "untilDismissed"]);
const BUTTON_ROLES = new Set(["primary", "secondary"]);
const MAX_BUTTONS = 2;
const ID_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const VERSION_RE = /^\d+(\.\d+)*$/;
const ACCENT_RE = /^#[0-9a-fA-F]{6}$/;
const ISO_INSTANT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

const PAYLOAD = JSON.stringify(validateCampaignCatalog(campaignCatalog));
const ETAG = `"${createHash("sha256").update(PAYLOAD).digest("base64url")}"`;

/**
 * Validates the checked-in catalog before it can be served. Throwing here
 * fails the build/test rather than shipping a malformed campaign to every
 * client, and mirrors what clients enforce so an entry that passes review
 * renders everywhere it targets.
 */
export function validateCampaignCatalog(input: unknown): CampaignCatalog {
  const catalog = record(input, "catalog");
  if (catalog.schemaVersion !== 1) {
    throw new Error("campaign catalog schemaVersion must be 1");
  }
  const updatedAt = isoInstant(catalog.updatedAt, "catalog.updatedAt");
  if (!Array.isArray(catalog.campaigns)) {
    throw new Error("catalog.campaigns must be an array");
  }

  const seenIDs = new Set<string>();
  const campaigns = catalog.campaigns.map((entry, index) => {
    const campaign = validateCampaign(entry, `campaigns[${index}]`);
    if (seenIDs.has(campaign.id)) {
      throw new Error(`campaigns[${index}] duplicates id ${campaign.id}`);
    }
    seenIDs.add(campaign.id);
    return campaign;
  });

  return { schemaVersion: 1, updatedAt, campaigns };
}

function validateCampaign(input: unknown, path: string): Campaign {
  const campaign = record(input, path);

  const id = nonemptyString(campaign.id, `${path}.id`);
  if (!ID_RE.test(id)) {
    throw new Error(`${path}.id must be a kebab-case slug, got "${id}"`);
  }
  const template = member(campaign.template, TEMPLATES, `${path}.template`);
  if (!Array.isArray(campaign.platforms) || campaign.platforms.length === 0) {
    throw new Error(`${path}.platforms must be a nonempty array`);
  }
  const platforms = campaign.platforms.map((value, index) =>
    member(value, PLATFORMS, `${path}.platforms[${index}]`),
  );
  const reshowPolicy = member(
    campaign.reshowPolicy,
    RESHOW_POLICIES,
    `${path}.reshowPolicy`,
  );

  const minAppVersion = optionalVersion(campaign.minAppVersion, `${path}.minAppVersion`);
  const maxAppVersion = optionalVersion(campaign.maxAppVersion, `${path}.maxAppVersion`);
  const startsAt = optionalInstant(campaign.startsAt, `${path}.startsAt`);
  const endsAt = optionalInstant(campaign.endsAt, `${path}.endsAt`);
  if (startsAt && endsAt && Date.parse(endsAt) <= Date.parse(startsAt)) {
    throw new Error(`${path}.endsAt must be after startsAt`);
  }

  if (campaign.rolloutPercent !== undefined) {
    const percent = campaign.rolloutPercent;
    if (typeof percent !== "number" || !Number.isFinite(percent) || percent < 0 || percent > 100) {
      throw new Error(`${path}.rolloutPercent must be a number in [0, 100]`);
    }
  }
  if (campaign.priority !== undefined && !Number.isInteger(campaign.priority)) {
    throw new Error(`${path}.priority must be an integer`);
  }
  if (campaign.showInWhatsNew !== undefined && typeof campaign.showInWhatsNew !== "boolean") {
    throw new Error(`${path}.showInWhatsNew must be a boolean`);
  }

  const title = localizedText(campaign.title, `${path}.title`);
  const body = localizedText(campaign.body, `${path}.body`);
  const image = campaign.image === undefined
    ? undefined
    : validateImage(campaign.image, `${path}.image`);
  if (campaign.accentColor !== undefined) {
    const accent = nonemptyString(campaign.accentColor, `${path}.accentColor`);
    if (!ACCENT_RE.test(accent)) {
      throw new Error(`${path}.accentColor must be "#RRGGBB"`);
    }
  }

  let buttons: CampaignButton[] | undefined;
  if (campaign.buttons !== undefined) {
    if (!Array.isArray(campaign.buttons) || campaign.buttons.length === 0) {
      throw new Error(`${path}.buttons must be a nonempty array when present`);
    }
    if (campaign.buttons.length > MAX_BUTTONS) {
      throw new Error(`${path}.buttons allows at most ${MAX_BUTTONS} entries`);
    }
    buttons = campaign.buttons.map((button, index) =>
      validateButton(button, `${path}.buttons[${index}]`),
    );
  }

  return {
    ...campaign,
    id,
    template,
    platforms,
    reshowPolicy,
    minAppVersion,
    maxAppVersion,
    startsAt,
    endsAt,
    title,
    body,
    image,
    buttons,
  } as Campaign;
}

function validateButton(input: unknown, path: string): CampaignButton {
  const button = record(input, path);
  const label = localizedText(button.label, `${path}.label`);
  const action = record(button.action, `${path}.action`);
  if (action.type === "openURL") {
    const url = nonemptyString(action.url, `${path}.action.url`);
    if (!/^https:\/\//.test(url)) {
      throw new Error(`${path}.action.url must be https`);
    }
  } else if (action.type !== "dismiss") {
    throw new Error(`${path}.action.type must be "openURL" or "dismiss"`);
  }
  if (button.role !== undefined) {
    member(button.role, BUTTON_ROLES, `${path}.role`);
  }
  return { ...button, label } as CampaignButton;
}

function validateImage(input: unknown, path: string): CampaignImage {
  const image = record(input, path);
  const light = imageURL(image.light, `${path}.light`);
  const dark = image.dark === undefined ? undefined : imageURL(image.dark, `${path}.dark`);
  if (image.aspectRatio !== undefined) {
    const ratio = image.aspectRatio;
    if (typeof ratio !== "number" || !Number.isFinite(ratio) || ratio <= 0) {
      throw new Error(`${path}.aspectRatio must be a positive number`);
    }
  }
  const alt = image.alt === undefined ? undefined : localizedText(image.alt, `${path}.alt`);
  return { ...image, light, dark, alt } as CampaignImage;
}

/** https URL, or a site-relative path under /campaigns/ (served from
 * web/public/campaigns/; the CI test checks the file exists). */
function imageURL(input: unknown, path: string): string {
  const url = nonemptyString(input, path);
  if (/^https:\/\//.test(url) || /^\/campaigns\/[A-Za-z0-9._\/-]+$/.test(url)) {
    return url;
  }
  throw new Error(`${path} must be an https URL or a /campaigns/... path`);
}

/** Every user-visible string ships both supported locales. */
function localizedText(input: unknown, path: string): CampaignText {
  const text = record(input, path);
  return {
    en: nonemptyString(text.en, `${path}.en`),
    ja: nonemptyString(text.ja, `${path}.ja`),
  };
}

function optionalVersion(input: unknown, path: string): string | undefined {
  if (input === undefined) return undefined;
  const version = nonemptyString(input, path);
  if (!VERSION_RE.test(version)) {
    throw new Error(`${path} must be a dotted numeric version, got "${version}"`);
  }
  return version;
}

function optionalInstant(input: unknown, path: string): string | undefined {
  if (input === undefined) return undefined;
  return isoInstant(input, path);
}

/** Requires a full date-time with timezone; clients reject date-only values,
 * so accepting them here would silently drop the campaign on device. */
function isoInstant(input: unknown, path: string): string {
  const value = nonemptyString(input, path);
  if (!ISO_INSTANT_RE.test(value) || Number.isNaN(Date.parse(value))) {
    throw new Error(`${path} must be an ISO-8601 instant with a timezone`);
  }
  return value;
}

function member<Value extends string>(
  input: unknown,
  allowed: Set<string>,
  path: string,
): Value {
  const value = nonemptyString(input, path);
  if (!allowed.has(value)) {
    throw new Error(`${path} must be one of ${[...allowed].join(", ")}, got "${value}"`);
  }
  return value as Value;
}

function record(input: unknown, path: string): Record<string, unknown> {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new Error(`${path} must be an object`);
  }
  return input as Record<string, unknown>;
}

function nonemptyString(input: unknown, path: string): string {
  if (typeof input !== "string" || input.trim().length === 0) {
    throw new Error(`${path} must be a nonempty string`);
  }
  return input.trim();
}

export async function GET(request: Request): Promise<Response> {
  if (matchesETag(request.headers.get("if-none-match"))) {
    return new Response(null, { status: 304, headers: commonHeaders() });
  }
  return new Response(PAYLOAD, {
    status: 200,
    headers: {
      ...commonHeaders(),
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

export function OPTIONS(): Response {
  return new Response(null, { status: 204, headers: commonHeaders() });
}

function commonHeaders(): Record<string, string> {
  return {
    "Cache-Control": CACHE_CONTROL,
    ETag: ETAG,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": ALLOW_METHODS,
    "Access-Control-Allow-Headers": ALLOW_HEADERS,
  };
}

function matchesETag(header: string | null): boolean {
  if (!header) return false;
  return header.split(",").some((value) => {
    const candidate = value.trim();
    return candidate === ETAG || candidate === "*";
  });
}
