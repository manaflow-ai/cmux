// The Page Info bubble's last cookie summary per site, for its next opening on the same site.
// The host pushes the bubble with `siteData: null` while it reads the site's cookies again, so the
// Cookies page showed a "Loading…" row on every opening, also for a site it read a moment ago. The
// bubble's page stays loaded across openings (each push names its `opening`), so it keeps the last
// summary per site in memory and draws it while the host reads; the host's read replaces it.
// Memory only, a few sites, counts only (no cookie names or values), gone with the page.
import type { PageInfoModel, SiteDataSummary } from "./model";

/** The bubble draws a site's last cookie summary while the host reads it again. False: "Loading…" as before. */
export const PAGE_INFO_LAST_SITE_DATA = true;

const LIMIT = 32;
const lastBySite = new Map<string, SiteDataSummary>();

function siteKey(model: PageInfoModel): string | undefined {
  return model.site.kind === "web" ? model.site.displayName : undefined;
}

/** `model` with the site's last summary in place of a null one; a pushed summary is kept for next time. */
export function withLastSiteData<Model extends PageInfoModel>(model: Model): Model {
  const key = siteKey(model);
  if (!PAGE_INFO_LAST_SITE_DATA || key === undefined) return model;
  if (model.siteData) {
    lastBySite.delete(key);
    lastBySite.set(key, model.siteData);
    while (lastBySite.size > LIMIT) {
      const oldest = lastBySite.keys().next().value;
      if (oldest === undefined) break;
      lastBySite.delete(oldest);
    }
    return model;
  }
  const last = lastBySite.get(key);
  return last ? { ...model, siteData: last } : model;
}

/** Forgets one site's summary (its data was deleted) or every site's (tests). */
export function forgetSiteData(site?: string): void {
  if (site === undefined) lastBySite.clear();
  else lastBySite.delete(site);
}
