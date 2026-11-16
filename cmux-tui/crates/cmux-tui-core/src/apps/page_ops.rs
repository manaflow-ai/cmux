//! Per-site browser ops for extensions (`browser.site.*`), beside the page
//! access of `browser.page.*` (provider family `browser.page`).
//!
//! - `browser.site.javascript.get` / `.set` go to the Mac app (provider
//!   family `browser.site`: Page Info's JavaScript row; `set` needs a
//!   gesture, capabilities.rs `PERSON_SPEND_OPS`).
//! - `browser.site.style.get` / `.set` are answered here. An extension keeps
//!   per-site element rules (`hide`, `unstick`: CSS selectors, checked here);
//!   the daemon persists them (`apps-site-styles.json`) and pushes the
//!   snapshot `apps-site-styles` to the connection that provides
//!   `browser.site` ([`PageStyles::told_locked`], from `Supervisor::emit`),
//!   which applies them at each document start for that origin. So a site an
//!   extension cleaned once is clean on the next visit with no extension call.
//!   Rules of an app that is uninstalled, turned off or held by safe mode
//!   stop applying.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const FILE: &str = "apps-site-styles.json";
/// Selectors per list (`hide`, `unstick`).
const MAX_SELECTORS: usize = 200;
const MAX_SELECTOR_BYTES: usize = 256;
/// Sites one extension may style.
const MAX_SITES: usize = 500;

#[derive(Debug)]
pub struct PageError {
    pub code: &'static str,
    pub message: String,
}

fn invalid(message: impl Into<String>) -> PageError {
    PageError { code: "validation.invalid", message: message.into() }
}

/// One site's rules from one extension.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rules {
    #[serde(default)]
    pub hide: Vec<String>,
    #[serde(default)]
    pub unstick: Vec<String>,
}

impl Rules {
    pub fn is_empty(&self) -> bool {
        self.hide.is_empty() && self.unstick.is_empty()
    }

    /// The style sheet: one rule per selector, so one selector the engine
    /// does not parse drops only itself.
    pub fn css(&self) -> String {
        let mut css = String::new();
        for selector in &self.hide {
            css.push_str(selector);
            css.push_str("{display:none!important}\n");
        }
        for selector in &self.unstick {
            css.push_str(selector);
            css.push_str("{position:static!important;top:auto!important;bottom:auto!important}\n");
        }
        css
    }
}

/// The `http(s)` origin `raw` names (`scheme://host[:port]`), lower-cased,
/// default ports dropped; anything else is refused.
pub fn origin(raw: &str) -> Result<String, PageError> {
    let url =
        url::Url::parse(raw.trim()).map_err(|_| invalid(format!("{raw} is not an origin")))?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none_or(str::is_empty) {
        return Err(invalid("origin must be an http or https origin"));
    }
    let origin = url.origin().ascii_serialization();
    if origin == "null" {
        return Err(invalid(format!("{raw} is not an origin")));
    }
    Ok(origin)
}

fn selectors(params: &Value, field: &str) -> Result<Vec<String>, PageError> {
    let Some(raw) = params.get(field).filter(|v| !v.is_null()) else { return Ok(Vec::new()) };
    let list =
        raw.as_array().ok_or_else(|| invalid(format!("{field} must be a list of selectors")))?;
    if list.len() > MAX_SELECTORS {
        return Err(invalid(format!("{field} has more than {MAX_SELECTORS} selectors")));
    }
    let mut out: Vec<String> = Vec::with_capacity(list.len());
    for item in list {
        let selector = item
            .as_str()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| invalid(format!("{field} must hold non-empty strings")))?;
        if selector.len() > MAX_SELECTOR_BYTES {
            return Err(invalid(format!("a selector is longer than {MAX_SELECTOR_BYTES} bytes")));
        }
        // A selector, never a rule: nothing that closes the rule, starts an
        // at-rule (`@import` would fetch), escapes or leaves the style element.
        if let Some(bad) = selector
            .chars()
            .find(|c| matches!(c, '{' | '}' | ';' | '<' | '>' | '@' | '\\') || c.is_control())
        {
            return Err(invalid(format!(
                "selector {selector:?} has {bad:?}, which a selector here may not"
            )));
        }
        if !out.iter().any(|s| s == selector) {
            out.push(selector.to_string());
        }
    }
    Ok(out)
}

/// `page.style.set` params: the origin and its rules (both lists empty
/// clears the site).
pub fn parse_set(params: &Value) -> Result<(String, Rules), PageError> {
    let raw = params
        .get("origin")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("origin is required"))?;
    Ok((
        origin(raw)?,
        Rules { hide: selectors(params, "hide")?, unstick: selectors(params, "unstick")? },
    ))
}

/// The installer the Mac app runs (isolated world) on a document of the
/// site: puts `css` in the app's own style element on the document element
/// (waiting for one when the document has none yet), or removes it when
/// `css` is empty. Idempotent.
pub fn installer(app: &str, css: &str) -> String {
    let app = serde_json::to_string(app).unwrap_or_default();
    let css = serde_json::to_string(css).unwrap_or_default();
    format!(
        r#"(()=>{{const app={app},css={css};const sel='style[data-cmux-site-style="'+app.replace(/"/g,'\\"')+'"]';const put=()=>{{const root=document.documentElement;if(!root)return false;for(const old of root.querySelectorAll(sel))old.remove();if(css){{const s=document.createElement("style");s.setAttribute("data-cmux-site-style",app);s.textContent=css;root.appendChild(s)}}return true}};if(!put()&&css){{const o=new MutationObserver(()=>{{if(put())o.disconnect()}});o.observe(document,{{childList:true}})}}}})()"#
    )
}

/// Every extension's site rules, persisted, and what the provider was told.
#[derive(Debug, Default)]
pub struct PageStyles {
    /// app -> origin -> rules.
    pub sites: BTreeMap<String, BTreeMap<String, Rules>>,
    /// The provider connection told last and the (app, origin) -> css it holds.
    told: Option<(u64, BTreeMap<(String, String), String>)>,
    /// Bumped by each change of `sites`; with the caller's own key it lets
    /// an emit with nothing new skip the snapshot (emits are frequent).
    revision: u64,
    told_key: Option<(u64, u64, u64)>,
}

impl PageStyles {
    pub fn load(state_dir: Option<&Path>) -> Self {
        let sites = state_dir
            .and_then(|dir| std::fs::read(dir.join(FILE)).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self { sites, ..Self::default() }
    }

    fn persist(&self, state_dir: Option<&Path>) -> std::io::Result<()> {
        use std::io::Write as _;
        let Some(dir) = state_dir else { return Ok(()) };
        std::fs::create_dir_all(dir)?;
        let temp = dir.join(format!("{FILE}.tmp"));
        let mut file = std::fs::File::create(&temp)?;
        file.write_all(&serde_json::to_vec(&self.sites).unwrap_or_default())?;
        file.sync_all()?;
        std::fs::rename(temp, dir.join(FILE))
    }

    pub fn get(&self, app: &str, origin: &str) -> Value {
        self.sites.get(app).and_then(|sites| sites.get(origin)).map_or(
            Value::Null,
            |r| json!({ "origin": origin, "hide": r.hide, "unstick": r.unstick }),
        )
    }

    /// Sets (or with empty rules clears) one site of `app`, and persists.
    pub fn set(
        &mut self,
        state_dir: Option<&Path>,
        app: &str,
        origin: String,
        rules: Rules,
    ) -> Result<Value, PageError> {
        let count = rules.hide.len() + rules.unstick.len();
        let sites = self.sites.entry(app.to_string()).or_default();
        if rules.is_empty() {
            sites.remove(&origin);
        } else {
            if !sites.contains_key(&origin) && sites.len() >= MAX_SITES {
                return Err(PageError {
                    code: "app.limit",
                    message: format!("an extension may style at most {MAX_SITES} sites"),
                });
            }
            sites.insert(origin.clone(), rules);
        }
        if sites.is_empty() {
            self.sites.remove(app);
        }
        self.revision += 1;
        self.persist(state_dir)
            .map_err(|e| PageError { code: "operation.failed", message: format!("{FILE}: {e}") })?;
        Ok(json!({ "origin": origin, "rules": count }))
    }

    /// Drops every site of an uninstalled app.
    pub fn forget(&mut self, state_dir: Option<&Path>, app: &str) {
        if self.sites.remove(app).is_some() {
            self.revision += 1;
            let _ = self.persist(state_dir);
        }
    }

    /// [`Self::told_locked`] when `provider`, the rules or `apps_key` (what
    /// decides `active`: the mirror revision, safe mode) changed since the
    /// last call; `None` at once otherwise.
    pub fn changed_locked(
        &mut self,
        provider: Option<u64>,
        apps_key: u64,
        active: impl Fn(&str) -> bool,
    ) -> Option<(u64, Value)> {
        let key = (provider.unwrap_or(0), self.revision, apps_key);
        if self.told_key == Some(key) {
            return None;
        }
        self.told_key = Some(key);
        self.told_locked(provider, active)
    }

    /// The `apps-site-styles` event for `provider` when what it should hold
    /// changed (a new provider connection gets the whole snapshot): the
    /// rules of apps that `active` says may run, and a removal (`css: ""`)
    /// for each pair it held that is gone.
    pub fn told_locked(
        &mut self,
        provider: Option<u64>,
        active: impl Fn(&str) -> bool,
    ) -> Option<(u64, Value)> {
        let Some(client) = provider else {
            self.told = None;
            return None;
        };
        let now: BTreeMap<(String, String), String> = self
            .sites
            .iter()
            .filter(|(app, _)| active(app))
            .flat_map(|(app, sites)| {
                sites.iter().map(move |(origin, r)| ((app.clone(), origin.clone()), r.css()))
            })
            .collect();
        let before = match &self.told {
            Some((told, held)) if *told == client => {
                if *held == now {
                    return None;
                }
                held.clone()
            }
            _ => BTreeMap::new(),
        };
        let entry = |(app, origin): &(String, String), css: &str| json!({ "app": app, "origin": origin, "css": css, "source": installer(app, css) });
        let mut styles: Vec<Value> = now.iter().map(|(key, css)| entry(key, css)).collect();
        styles
            .extend(before.keys().filter(|key| !now.contains_key(*key)).map(|key| entry(key, "")));
        self.told = Some((client, now));
        Some((client, json!({ "event": "apps-site-styles", "styles": styles })))
    }
}

/// Whether the daemon answers `op` itself (`browser.site.javascript.*` goes
/// to the provider).
pub fn daemon_owned(op: &str) -> bool {
    matches!(op, "browser.site.style.get" | "browser.site.style.set")
}

impl super::supervisor::Supervisor {
    /// The `apps-site-styles` event the `page` provider is owed, if any;
    /// recomputed at each emit (`Supervisor::emit`). Only apps that are
    /// installed, turned on and not held by safe mode style pages.
    pub(super) fn page_styles_locked(
        inner: &mut super::supervisor::Inner,
    ) -> Option<super::supervisor::Out> {
        let provider =
            inner.providers.get("browser.site").copied().filter(|id| inner.sinks.contains_key(id));
        let safe = inner.safe_mode.is_some();
        let apps = &inner.mirror.apps;
        let key = inner.mirror.revision.wrapping_mul(2) | u64::from(safe);
        inner
            .page_styles
            .changed_locked(provider, key, |app| {
                !safe && apps.get(app).is_some_and(|r| r.installed && r.enabled)
            })
            .map(|(client, event)| super::supervisor::Out::Client(client, event))
    }

    /// `page.style.get` / `page.style.set` for `app` (scope and grant checked).
    pub(super) fn page_style_call(
        &self,
        app: &str,
        op: &str,
        params: &Value,
    ) -> Result<Value, Value> {
        let fail =
            |e: PageError| json!({ "code": e.code, "message": e.message, "retryable": false });
        let value = {
            let mut inner = self.inner.lock().unwrap();
            if op == "browser.site.style.get" {
                let raw = params.get("origin").and_then(Value::as_str).unwrap_or_default();
                let origin = origin(raw).map_err(fail)?;
                return Ok(json!({ "value": inner.page_styles.get(app, &origin) }));
            }
            let (origin, rules) = parse_set(params).map_err(fail)?;
            inner
                .page_styles
                .set(self.config.state_dir.as_deref(), app, origin, rules)
                .map_err(fail)?
        };
        // Tells the provider now, not at the next unrelated emit.
        self.emit(Vec::new());
        Ok(json!({ "value": value }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origins_are_http_origins_only() {
        assert_eq!(origin("https://News.Example.com/a?b").unwrap(), "https://news.example.com");
        assert_eq!(origin("http://a.test:80").unwrap(), "http://a.test");
        assert_eq!(origin("http://a.test:8080/x").unwrap(), "http://a.test:8080");
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "cmux://x", "news", ""] {
            assert!(origin(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn selectors_cannot_leave_their_rule() {
        let ok = json!({ "origin": "https://a.test", "hide": [".ad", "#cookie-banner", ".ad", "div[data-x=\"y\"]"], "unstick": ["header.site"] });
        let (origin, rules) = parse_set(&ok).unwrap();
        assert_eq!(origin, "https://a.test");
        assert_eq!(rules.hide, vec![".ad", "#cookie-banner", "div[data-x=\"y\"]"]);
        assert_eq!(
            rules.css(),
            ".ad{display:none!important}\n#cookie-banner{display:none!important}\ndiv[data-x=\"y\"]{display:none!important}\nheader.site{position:static!important;top:auto!important;bottom:auto!important}\n"
        );
        for bad in [".a{}", ".a;b", "@import url(x)", "</style>", ".a\\7b", ".a\n.b", ""] {
            let params = json!({ "origin": "https://a.test", "hide": [bad] });
            assert!(parse_set(&params).is_err(), "{bad:?}");
        }
        let many: Vec<String> = (0..=MAX_SELECTORS).map(|i| format!(".a{i}")).collect();
        assert!(parse_set(&json!({ "origin": "https://a.test", "hide": many })).is_err());
        assert!(parse_set(&json!({ "hide": [".a"] })).is_err());
    }

    #[test]
    fn set_persists_and_clear_removes() {
        let dir = tempfile::tempdir().unwrap();
        let mut styles = PageStyles::default();
        let rules = Rules { hide: vec![".ad".into()], unstick: vec![] };
        styles.set(Some(dir.path()), "local/x", "https://a.test".into(), rules.clone()).unwrap();
        let loaded = PageStyles::load(Some(dir.path()));
        assert_eq!(
            loaded.get("local/x", "https://a.test"),
            json!({ "origin": "https://a.test", "hide": [".ad"], "unstick": [] })
        );
        styles.set(Some(dir.path()), "local/x", "https://a.test".into(), Rules::default()).unwrap();
        assert!(PageStyles::load(Some(dir.path())).sites.is_empty());
    }

    #[test]
    fn the_provider_hears_a_snapshot_then_only_changes() {
        let mut styles = PageStyles::default();
        let rules = Rules { hide: vec![".ad".into()], unstick: vec![] };
        styles.set(None, "local/x", "https://a.test".into(), rules.clone()).unwrap();
        styles.set(None, "local/off", "https://a.test".into(), rules).unwrap();
        assert!(styles.told_locked(None, |_| true).is_none());
        let (client, event) = styles.told_locked(Some(7), |app| app == "local/x").unwrap();
        assert_eq!(client, 7);
        let list = event["styles"].as_array().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["css"], ".ad{display:none!important}\n");
        assert!(list[0]["source"].as_str().unwrap().contains("data-cmux-site-style"));
        // Nothing changed: nothing to tell.
        assert!(styles.told_locked(Some(7), |app| app == "local/x").is_none());
        // The app is turned off: its site is removed on open tabs.
        let (_, event) = styles.told_locked(Some(7), |_| false).unwrap();
        assert_eq!(
            event["styles"],
            json!([{ "app": "local/x", "origin": "https://a.test", "css": "", "source": installer("local/x", "") }])
        );
        // A new provider connection gets the whole snapshot again.
        let (client, event) = styles.told_locked(Some(9), |_| true).unwrap();
        assert_eq!((client, event["styles"].as_array().unwrap().len()), (9, 2));
    }

    #[test]
    fn the_site_cap_holds_per_app() {
        let mut styles = PageStyles::default();
        let rules = Rules { hide: vec![".ad".into()], unstick: vec![] };
        for i in 0..MAX_SITES {
            styles.set(None, "local/x", format!("https://s{i}.test"), rules.clone()).unwrap();
        }
        let over =
            styles.set(None, "local/x", "https://over.test".into(), rules.clone()).unwrap_err();
        assert_eq!(over.code, "app.limit");
        // Replacing a site it has is fine.
        styles.set(None, "local/x", "https://s0.test".into(), rules).unwrap();
    }
}
