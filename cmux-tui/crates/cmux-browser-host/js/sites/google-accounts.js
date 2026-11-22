// sites.googleAccounts: the Google accounts signed in to the cmux browser,
// with their /u/{uid}/ index, from Google's ListAccounts endpoint (the one
// Chromium's account reconcilor uses; shape parsed as in Chromium's
// google_apis/gaia/gaia_auth_util.cc: [2] name, [3] email, [14] signed
// out). Cookie-only, no tab.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  S.register(
    "googleAccounts",
    (t) => ({
      // [{ uid, name, email, signedOut }]; uid is the /u/{uid}/ and authuser index.
      async list() {
        const r = await t.fetch("https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "" });
        if (!r.ok) throw new S.SiteError("http", `googleAccounts.list: HTTP ${r.status}`);
        let data;
        try {
          data = JSON.parse((await r.text()).replace(/^\)\]\}'\s*/, ""));
        } catch {
          throw new S.SiteError("unexpected", "googleAccounts.list: Google's answer was not the ListAccounts JSON");
        }
        const rows = Array.isArray(data) && Array.isArray(data[1]) ? data[1] : [];
        return rows
          .filter((a) => Array.isArray(a) && typeof a[3] === "string")
          .map((a, i) => ({ uid: i, name: typeof a[2] === "string" ? a[2] : "", email: a[3], signedOut: a[14] === 1 || a[14] === true }));
      },
    }),
    { summary: "Signed-in Google accounts and their uid (/u/{uid}/) index" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
