//! This Mac's look for its phones (`appearance-v1`,
//! cmux-next-ios/PROTOCOL.md "Appearance"): the terminal theme resolved here
//! with `cmux-theme-tokens` (the user's Ghostty config with
//! `appearance.theme` over it, once dark and once light), the appearance
//! settings the phone draws with, and the backdrop image the Mac app shows
//! (`set-appearance-background`, kept in memory only).
//!
//! Every change (a listed settings key, a watched Ghostty file, the
//! background) advances one revision; `appearance-changed {revision}` leaves
//! at once for the first change and then at most once per
//! [`COALESCE_WINDOW`], carrying the newest revision.

use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, Weak};
use std::time::Duration;

use cmux_theme_tokens::{Appearance, Env, Loaded, Rgb, ThemeInput, parse_color};
use serde_json::{Map, Value, json};

use super::{Mux, MuxEvent};

/// The daemon serves `get-appearance`, `set-appearance-background` and
/// emits `appearance-changed`.
pub const APPEARANCE_CAPABILITY: &str = "appearance-v1";
/// Shortest gap between two `appearance-changed` events.
pub const COALESCE_WINDOW: Duration = Duration::from_millis(50);
/// Largest background file the daemon accepts (the app exports at most
/// 2560 px on the long side as JPEG, far below this).
pub const MAX_BACKGROUND_BYTES: u64 = 32 * 1024 * 1024;

/// Settings keys the snapshot reads; a change to one (or to a key below
/// one, such as `home.bubbleColors.sent`) is an appearance change.
const APPEARANCE_KEYS: &[&str] = &[
    "appearance.theme",
    "appearance.themeEdits",
    "appearance.highlightColor",
    "appearance.accent",
    "appearance.chromeStyle",
    "appearance.hue",
    "appearance.saturation",
    "appearance.glassTransparency",
    "appearance.sidebarSurface",
    "appearance.background",
    "appearance.backgroundOpacity",
    "appearance.backgroundBlur",
    "terminal.fontFamily",
    "terminal.fontSize",
    "home.bubbleColors",
    "sidebar.groupPalette",
    "sidebar.groupGradient",
];

/// The keys that change the resolved theme (its cache is dropped).
const THEME_KEYS: &[&str] =
    &["appearance.theme", "appearance.themeEdits", "appearance.highlightColor"];

/// Whether a settings change of `keys` touches one of `list` (the key
/// itself, a key below it, or a parent of it).
fn touches(keys: &[String], list: &[&str]) -> bool {
    keys.iter().any(|key| {
        list.iter().any(|listed| {
            key == listed
                || key.strip_prefix(listed).is_some_and(|rest| rest.starts_with('.'))
                || listed.strip_prefix(key.as_str()).is_some_and(|rest| rest.starts_with('.'))
        })
    })
}

/// The backdrop image the Mac app shows, as it exported it.
#[derive(Clone, Debug, PartialEq)]
pub struct AppearanceBackground {
    /// The exported JPEG (`mobile-appearance/<sha256>.jpg`); never sent to a phone.
    pub path: PathBuf,
    /// Lowercase hex SHA-256 of the file.
    pub sha256: String,
    /// The file's size when it was set.
    pub bytes: u64,
    pub width: u32,
    pub height: u32,
    /// Average relative luminance, 0...1.
    pub luminance: f64,
}

impl AppearanceBackground {
    /// Checks a `set-appearance-background` value: an absolute path to a
    /// regular file of at most [`MAX_BACKGROUND_BYTES`], a 64-digit hex
    /// hash, a size and a luminance in range.
    pub fn validated(
        path: String,
        sha256: String,
        width: u32,
        height: u32,
        luminance: f64,
    ) -> anyhow::Result<Self> {
        let path = PathBuf::from(path);
        anyhow::ensure!(path.is_absolute(), "bad request: background path must be absolute");
        let sha256 = sha256.to_ascii_lowercase();
        anyhow::ensure!(
            sha256.len() == 64 && sha256.bytes().all(|b| b.is_ascii_hexdigit()),
            "bad request: sha256 must be 64 hex digits"
        );
        anyhow::ensure!(
            (1..=65_535).contains(&width) && (1..=65_535).contains(&height),
            "bad request: width and height must be 1 to 65535"
        );
        anyhow::ensure!(
            luminance.is_finite() && (0.0..=1.0).contains(&luminance),
            "bad request: luminance must be 0 to 1"
        );
        let metadata = std::fs::metadata(&path)
            .map_err(|error| anyhow::anyhow!("bad request: background file: {error}"))?;
        anyhow::ensure!(metadata.is_file(), "bad request: background is not a regular file");
        anyhow::ensure!(
            metadata.len() > 0 && metadata.len() <= MAX_BACKGROUND_BYTES,
            "bad request: background file must be 1 byte to 32 MiB"
        );
        Ok(Self { path, sha256, bytes: metadata.len(), width, height, luminance })
    }
}

/// Per-mux appearance state; the pump thread and the Ghostty watcher hold
/// it weakly or through the shared half only, never the mux.
#[derive(Default)]
pub(crate) struct AppearanceSlot(Arc<Shared>);

#[derive(Default)]
struct Shared {
    state: Mutex<Inner>,
    wake: Condvar,
    mux: OnceLock<Weak<Mux>>,
    pump: OnceLock<()>,
}

#[derive(Default)]
struct Inner {
    revision: u64,
    emitted: u64,
    background: Option<AppearanceBackground>,
    /// The resolved theme while nothing it depends on changed.
    theme: Option<Arc<ThemeSnapshot>>,
    /// Advances whenever `theme` is dropped, so a resolve that raced a
    /// change is not cached.
    theme_generation: u64,
    watcher: Option<(Vec<PathBuf>, cmux_config::Watcher)>,
    /// Tests resolve against fixed Ghostty files.
    env: Option<Env>,
}

/// The theme JSON and the files whose change changes it.
struct ThemeSnapshot {
    json: Value,
    watch: Vec<PathBuf>,
}

/// What the snapshot reads from the settings file.
struct SettingsInputs {
    theme: Option<String>,
    edits: Option<Value>,
    highlight: Option<String>,
    values: Vec<(&'static str, Option<Value>)>,
}

fn lock(shared: &Shared) -> MutexGuard<'_, Inner> {
    shared.state.lock().unwrap_or_else(|poison| poison.into_inner())
}

impl Shared {
    fn attach(self: &Arc<Self>, mux: &Arc<Mux>) {
        self.mux.get_or_init(|| Arc::downgrade(mux));
    }

    /// Advances the revision and wakes the pump (started on first use).
    fn bump(self: &Arc<Self>) -> u64 {
        let revision = {
            let mut inner = lock(self);
            inner.revision += 1;
            inner.revision
        };
        self.wake.notify_one();
        if self.mux.get().is_some() {
            self.pump.get_or_init(|| {
                let shared = Arc::clone(self);
                let _ = std::thread::Builder::new()
                    .name("cmux-appearance".into())
                    .spawn(move || pump(&shared));
            });
        }
        revision
    }

    fn drop_theme(&self) {
        let mut inner = lock(self);
        inner.theme = None;
        inner.theme_generation += 1;
    }

    fn mux_gone(&self) -> bool {
        self.mux.get().is_none_or(|mux| mux.strong_count() == 0)
    }

    /// The resolved theme for `inputs`, from the cache or read now; (re)starts
    /// the Ghostty watcher when the files it depends on changed.
    fn theme(self: &Arc<Self>, inputs: &SettingsInputs) -> Arc<ThemeSnapshot> {
        let (generation, env, watched) = {
            let inner = lock(self);
            if let Some(theme) = &inner.theme {
                return Arc::clone(theme);
            }
            let watched = inner.watcher.as_ref().map(|(paths, _)| paths.clone());
            (inner.theme_generation, inner.env.clone(), watched)
        };
        let theme = Arc::new(resolve_theme(env.unwrap_or_else(daemon_env), inputs));
        let watcher = (watched.as_ref() != Some(&theme.watch))
            .then(|| {
                let weak = Arc::downgrade(self);
                cmux_config::Watcher::start(theme.watch.clone(), move || {
                    let Some(shared) = weak.upgrade() else { return };
                    shared.drop_theme();
                    shared.bump();
                })
                .ok()
                .map(|watcher| (theme.watch.clone(), watcher))
            })
            .flatten();
        let replaced = {
            let mut inner = lock(self);
            if inner.theme_generation == generation {
                inner.theme = Some(Arc::clone(&theme));
            }
            match watcher {
                Some(watcher) => inner.watcher.replace(watcher),
                None => None,
            }
        };
        // Stopped outside the lock: its thread may be waiting for it.
        drop(replaced);
        theme
    }
}

/// Emits the newest revision at once, then waits [`COALESCE_WINDOW`] before
/// the next, so a burst of changes is one event per window. Ends with its mux.
fn pump(shared: &Arc<Shared>) {
    loop {
        let revision = {
            let mut inner = lock(shared);
            loop {
                if inner.revision > inner.emitted {
                    inner.emitted = inner.revision;
                    break inner.revision;
                }
                if shared.mux_gone() {
                    return;
                }
                inner = shared
                    .wake
                    .wait_timeout(inner, Duration::from_secs(1))
                    .unwrap_or_else(|poison| poison.into_inner())
                    .0;
            }
        };
        let Some(mux) = shared.mux.get().and_then(Weak::upgrade) else { return };
        mux.emit(MuxEvent::AppearanceChanged { revision });
        drop(mux);
        std::thread::sleep(COALESCE_WINDOW);
    }
}

/// The process environment, plus the app bundle's Ghostty resources when
/// the daemon runs from `Contents/Resources/bin` and nothing names them.
fn daemon_env() -> Env {
    let mut env = Env::current();
    if env.ghostty_resources_dir.is_none()
        && let Some(exe) = &env.exe_dir
    {
        let bundled = exe.join("../ghostty");
        if bundled.join("themes").is_dir() {
            env.ghostty_resources_dir = Some(bundled);
        }
    }
    env
}

/// `#RRGGBB`.
fn hex(color: Rgb) -> String {
    format!("#{:06X}", color.to_hex())
}

/// `ThemeInput` as PROTOCOL.md's `THEME_INPUT` (optional colors omitted
/// when unset; `accent` is `appearance.accent`, sent on its own).
pub(crate) fn theme_input_json(input: &ThemeInput) -> Value {
    let mut object = Map::new();
    object.insert("background".into(), hex(input.background).into());
    object.insert("foreground".into(), hex(input.foreground).into());
    object.insert("palette".into(), input.palette.iter().map(|c| Value::from(hex(*c))).collect());
    let optional = [
        ("selection_background", input.selection_background),
        ("selection_foreground", input.selection_foreground),
        ("cursor", input.cursor),
        ("accent_color", input.accent_color),
    ];
    for (key, color) in optional {
        if let Some(color) = color {
            object.insert(key.into(), hex(color).into());
        }
    }
    object.insert("background_opacity".into(), json!(input.background_opacity));
    object.insert("background_blur".into(), json!(input.background_blur));
    Value::Object(object)
}

/// The app's edits of theme `name` (`appearance.themeEdits`, keyed
/// `"<theme>/<token>"` as Swift `ThemeEditsSetting` reads them) and its
/// highlight (`appearance.highlightColor`) over a loaded theme.
fn apply_edits(
    input: &mut ThemeInput,
    name: Option<&str>,
    edits: Option<&Value>,
    highlight: Option<&str>,
) {
    let color = |text: &str| {
        (text.len() == 7 && text.starts_with('#')).then(|| parse_color(text)).flatten()
    };
    for (key, value) in edits.and_then(Value::as_object).into_iter().flatten() {
        let Some((theme, token)) = key.rsplit_once('/') else { continue };
        if Some(theme) != name {
            continue;
        }
        let Some(rgb) = value.as_str().and_then(color) else { continue };
        match token {
            "background" => input.background = rgb,
            "foreground" => input.foreground = rgb,
            "cursor" => input.cursor = Some(rgb),
            "selection" => input.selection_background = Some(rgb),
            "accent" => input.accent_color = Some(rgb),
            index => {
                if let Some(slot) =
                    index.parse::<usize>().ok().and_then(|index| input.palette.get_mut(index))
                {
                    *slot = rgb;
                }
            }
        }
    }
    if let Some(rgb) = highlight.and_then(color) {
        input.selection_background = Some(rgb);
    }
}

/// Resolves the theme for both appearances, as the Mac app's terminal does:
/// cmux-next's default theme pair before the user's files, `appearance.theme`
/// over them.
fn resolve_theme(base: Env, inputs: &SettingsInputs) -> ThemeSnapshot {
    let mut env = base;
    if env.default_theme.is_none() {
        env.default_theme = env.default_theme_spec(true);
    }
    let env = match inputs.theme.as_deref() {
        Some(spec) => env.clone().with_theme_override(spec).unwrap_or(env),
        None => env,
    };
    let dark = cmux_theme_tokens::load(&env, Appearance::Dark);
    let light = cmux_theme_tokens::load(&env, Appearance::Light);
    let follows_system = dark.theme != light.theme || dark.theme_file != light.theme_file;
    let side = |loaded: &Loaded| {
        let mut input = loaded.input;
        apply_edits(
            &mut input,
            loaded.theme.as_deref(),
            inputs.edits.as_ref(),
            inputs.highlight.as_deref(),
        );
        json!({"name": loaded.theme, "input": theme_input_json(&input)})
    };
    let json = json!({
        "dark": side(&dark),
        "light": side(&light),
        "follows_system": follows_system,
    });
    let mut watch: Vec<PathBuf> = dark.watch_paths().to_vec();
    for path in light.watch_paths() {
        if !watch.contains(path) {
            watch.push(path.clone());
        }
    }
    ThemeSnapshot { json, watch }
}

/// The snapshot's pass-through fields: (JSON path, settings key).
const VALUES: &[(&str, &str)] = &[
    ("accent", "appearance.accent"),
    ("chrome_style", "appearance.chromeStyle"),
    ("hue", "appearance.hue"),
    ("saturation", "appearance.saturation"),
    ("glass_transparency", "appearance.glassTransparency"),
    ("sidebar_surface", "appearance.sidebarSurface"),
    ("terminal.font_family", "terminal.fontFamily"),
    ("terminal.font_size", "terminal.fontSize"),
    ("chat.sent", "home.bubbleColors.sent"),
    ("chat.sent_text", "home.bubbleColors.sentText"),
    ("chat.received", "home.bubbleColors.received"),
    ("chat.received_text", "home.bubbleColors.receivedText"),
    ("groups.palette", "sidebar.groupPalette"),
    ("groups.gradient", "sidebar.groupGradient"),
    ("background_opacity", "appearance.backgroundOpacity"),
    ("background_blur", "appearance.backgroundBlur"),
];

fn setting(state: &cmux_config::State, key: &str) -> Option<Value> {
    let view = state.get(&cmux_config::Target::Key(key.to_string()));
    view.row.and_then(|row| row.value).or(view.value).filter(|value| !value.is_null())
}

fn read_settings(state: &cmux_config::State) -> SettingsInputs {
    let text = |key: &str| setting(state, key).and_then(|v| v.as_str().map(str::to_owned));
    SettingsInputs {
        theme: text("appearance.theme").filter(|theme| !theme.trim().is_empty()),
        edits: setting(state, "appearance.themeEdits"),
        highlight: text("appearance.highlightColor"),
        values: VALUES.iter().map(|(path, key)| (*path, setting(state, key))).collect(),
    }
}

/// The `get-appearance` answer from its parts.
fn snapshot_json(
    revision: u64,
    theme: &Value,
    inputs: &SettingsInputs,
    background: Option<&AppearanceBackground>,
    include_path: bool,
) -> Value {
    let value = |path: &str| {
        inputs
            .values
            .iter()
            .find(|(known, _)| *known == path)
            .and_then(|(_, value)| value.clone())
            .unwrap_or(Value::Null)
    };
    let background = background.map(|background| {
        let mut object = json!({
            "sha256": background.sha256,
            "bytes": background.bytes,
            "width": background.width,
            "height": background.height,
            "luminance": background.luminance,
            "opacity": value("background_opacity"),
            "blur": value("background_blur"),
        });
        if include_path {
            object["path"] = Value::from(background.path.to_string_lossy().into_owned());
        }
        object
    });
    json!({
        "revision": revision,
        "theme": theme,
        "accent": value("accent"),
        "chrome_style": value("chrome_style"),
        "hue": value("hue"),
        "saturation": value("saturation"),
        "glass_transparency": value("glass_transparency"),
        "sidebar_surface": value("sidebar_surface"),
        "terminal": {
            "font_family": value("terminal.font_family"),
            "font_size": value("terminal.font_size"),
        },
        "chat": {
            "sent": value("chat.sent"),
            "sent_text": value("chat.sent_text"),
            "received": value("chat.received"),
            "received_text": value("chat.received_text"),
        },
        "groups": {
            "palette": value("groups.palette"),
            "gradient": value("groups.gradient"),
        },
        "background": background,
    })
}

impl Mux {
    /// The `get-appearance` snapshot. `include_path` adds the background
    /// file's path (the caller checked the connection may read it).
    pub fn appearance_snapshot(self: &Arc<Self>, include_path: bool) -> Value {
        let shared = &self.appearance.0;
        shared.attach(self);
        let inputs = self.with_settings(read_settings);
        let theme = shared.theme(&inputs);
        let (revision, background) = {
            let inner = lock(shared);
            (inner.revision, inner.background.clone())
        };
        snapshot_json(revision, &theme.json, &inputs, background.as_ref(), include_path)
    }

    /// The current appearance revision.
    pub fn appearance_revision(&self) -> u64 {
        lock(&self.appearance.0).revision
    }

    /// Replaces the background the app shows; a change advances the
    /// revision. Returns the revision in effect.
    pub fn set_appearance_background(
        self: &Arc<Self>,
        background: Option<AppearanceBackground>,
    ) -> u64 {
        let shared = &self.appearance.0;
        shared.attach(self);
        {
            let mut inner = lock(shared);
            if inner.background == background {
                return inner.revision;
            }
            inner.background = background;
        }
        shared.bump()
    }

    /// The settings owner saw a change of `keys` (mux/settings.rs).
    pub(crate) fn note_appearance_settings(self: &Arc<Self>, keys: &[String]) {
        if !touches(keys, APPEARANCE_KEYS) {
            return;
        }
        let shared = &self.appearance.0;
        shared.attach(self);
        if touches(keys, THEME_KEYS) {
            shared.drop_theme();
        }
        shared.bump();
    }

    /// An appearance change from outside the settings file (a test, a
    /// Ghostty file); advances the revision.
    pub(crate) fn note_appearance_changed(self: &Arc<Self>) -> u64 {
        let shared = &self.appearance.0;
        shared.attach(self);
        shared.drop_theme();
        shared.bump()
    }

    /// Resolves the theme against `env` instead of the process environment.
    #[cfg(test)]
    pub(crate) fn set_appearance_env_for_test(&self, env: Env) {
        let mut inner = lock(&self.appearance.0);
        inner.env = Some(env);
        inner.theme = None;
        inner.theme_generation += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appearance_keys_match_children_and_parents() {
        let keys = |list: &[&str]| list.iter().map(|key| key.to_string()).collect::<Vec<_>>();
        assert!(touches(&keys(&["home.bubbleColors.sent"]), APPEARANCE_KEYS));
        assert!(touches(&keys(&["appearance"]), APPEARANCE_KEYS));
        assert!(touches(&keys(&["appearance.backgroundOpacity"]), APPEARANCE_KEYS));
        assert!(!touches(&keys(&["appearance.iconTheme"]), APPEARANCE_KEYS));
        assert!(!touches(&keys(&["appearance.themeFile"]), THEME_KEYS));
        assert!(!touches(&keys(&["notifications.sound"]), APPEARANCE_KEYS));
    }

    #[test]
    fn theme_input_json_has_the_protocol_shape() {
        let mut input = ThemeInput::GHOSTTY_DEFAULT;
        let value = theme_input_json(&input);
        assert_eq!(value["background"], "#282C34");
        assert_eq!(value["palette"].as_array().unwrap().len(), 16);
        assert!(value.get("cursor").is_none());
        assert!(value.get("accent_color").is_none());
        assert!(value.get("accent").is_none());
        let edits = json!({
            "Nord/cursor": "#ff0000",
            "Nord/3": "#00ff00",
            "Nord/accent": "#0000ff",
            "Nord/bogus": "#ffffff",
            "Nord/background": "nope",
            "Other/foreground": "#ffffff",
        });
        apply_edits(&mut input, Some("Nord"), Some(&edits), Some("#123456"));
        let value = theme_input_json(&input);
        assert_eq!(value["cursor"], "#FF0000");
        assert_eq!(value["palette"][3], "#00FF00");
        assert_eq!(value["accent_color"], "#0000FF");
        assert_eq!(value["selection_background"], "#123456");
        assert_eq!(value["background"], "#282C34");
        assert_eq!(value["foreground"], "#FFFFFF");
    }

    #[test]
    fn background_validation_refuses_bad_values() {
        let dir = std::env::temp_dir().join(format!("cmux-appearance-bg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("a.jpg");
        std::fs::write(&file, b"jpeg").unwrap();
        let path = file.to_string_lossy().into_owned();
        let hash = "a".repeat(64);
        let ok = AppearanceBackground::validated(path.clone(), hash.to_uppercase(), 10, 20, 0.5)
            .unwrap();
        assert_eq!(ok.bytes, 4);
        assert_eq!(ok.sha256, hash);
        assert!(
            AppearanceBackground::validated("rel.jpg".into(), hash.clone(), 1, 1, 0.5).is_err()
        );
        assert!(AppearanceBackground::validated(path.clone(), "zz".into(), 1, 1, 0.5).is_err());
        assert!(AppearanceBackground::validated(path.clone(), hash.clone(), 0, 1, 0.5).is_err());
        assert!(AppearanceBackground::validated(path.clone(), hash.clone(), 1, 1, 1.5).is_err());
        assert!(
            AppearanceBackground::validated(
                dir.to_string_lossy().into_owned(),
                hash.clone(),
                1,
                1,
                0.5
            )
            .is_err()
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
