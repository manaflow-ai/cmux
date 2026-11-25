//! A look's variants: the theme files its layer ships (`themes/NAME.json`),
//! one of them picked inside that layer.
//!
//! Picking a variant with `cmux settings set appearance.themeFile NAME`
//! writes your own settings; once any apply keeps that value as yours,
//! removing the look deletes its theme file and leaves the setting naming a
//! file that is gone. `cmux setup variant LOOK NAME` sets the key in the
//! look's own library entry instead, so it goes with the look; and a remove
//! clears a `themeFile` that names one of the theme files it took away.

use serde_json::Value;

use super::{Receipt, settings_error, settings_text};
use crate::tree::{self, SETTINGS};
use crate::{Customize, Error};

/// The setting a variant picks.
pub const THEME_FILE_KEY: &str = "appearance.themeFile";
const THEME_FILE_PATH: [&str; 2] = ["appearance", "themeFile"];

/// The theme names a set of file paths holds (`themes/NAME.json`), sorted.
fn theme_names(files: &[String]) -> Vec<String> {
    let mut names: Vec<String> = files
        .iter()
        .filter_map(|path| path.strip_prefix("themes/")?.strip_suffix(".json"))
        .filter(|name| !name.contains('/'))
        .map(str::to_owned)
        .collect();
    names.sort();
    names.dedup();
    names
}

impl Customize {
    /// The variants an installed setup ships, and the one its layer picks.
    pub fn setup_variants(
        &self,
        receipt: &Receipt,
    ) -> Result<(Vec<String>, Option<String>), Error> {
        let Some(name) = &receipt.library else { return Ok((Vec::new(), None)) };
        let files = self.library_entry_files(name)?.unwrap_or_default();
        let picked = self
            .library_entry_setting(name, THEME_FILE_KEY)?
            .and_then(|value| value.as_str().map(str::to_owned));
        Ok((theme_names(&files), picked))
    }

    /// Picks `variant` (one of [`Customize::setup_variants`]) inside the
    /// setup's own layer: one applied generation; removing the setup takes
    /// it off with the rest.
    pub fn setup_variant(
        &self,
        receipt: &Receipt,
        variant: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<(), Error> {
        let (variants, _) = self.setup_variants(receipt)?;
        let Some(entry) = receipt.library.as_deref().filter(|_| !variants.is_empty()) else {
            return Err(Error::Setup(format!("{} ships no theme files to pick", receipt.id)));
        };
        if !variants.iter().any(|name| name == variant) {
            return Err(Error::Setup(format!(
                "{} has no variant {variant:?}; it ships: {}",
                receipt.id,
                variants.join(", ")
            )));
        }
        self.no_preview_open()?;
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        let label = format!("setup {}: variant {variant}", receipt.id);
        self.library_entry_set_locked(
            entry,
            THEME_FILE_KEY,
            Value::String(variant.to_owned()),
            &label,
            origin,
            now_ms,
        )?;
        // A variant picked by hand before (`cmux settings set`) may sit in
        // your own settings over the layer: the layer's pick is the one now.
        let text = settings_text(self)?;
        let file = cmux_config::jsonc::parse(&text).unwrap_or(Value::Null);
        let path: Vec<String> = THEME_FILE_PATH.iter().map(|piece| (*piece).to_owned()).collect();
        if cmux_config::value::value_at(&file, &path).and_then(Value::as_str) != Some(variant) {
            let text = cmux_config::jsonc::set(&text, &path, &Value::String(variant.to_owned()))
                .map_err(settings_error)?;
            tree::write(self.roots(), SETTINGS, text.as_bytes(), false)?;
            self.apply_locked(Some(&label), origin, now_ms)?;
        }
        Ok(())
    }

    /// After a remove took `removed` (file paths) away: when the settings'
    /// `themeFile` names one of those theme files and it is gone, the key
    /// comes out, so cmux shows its own theme rather than a missing file.
    /// Returns whether it changed the settings (the caller applies).
    pub(super) fn clear_removed_theme_file(&self, removed: &[String]) -> Result<bool, Error> {
        let names = theme_names(removed);
        if names.is_empty() {
            return Ok(false);
        }
        let text = settings_text(self)?;
        let file = cmux_config::jsonc::parse(&text).unwrap_or(Value::Null);
        let path: Vec<String> = THEME_FILE_PATH.iter().map(|piece| (*piece).to_owned()).collect();
        let Some(theme) = cmux_config::value::value_at(&file, &path).and_then(Value::as_str) else {
            return Ok(false);
        };
        let gone = names.iter().any(|name| name == theme)
            && tree::read(self.roots(), &format!("themes/{theme}.json"))?.is_none();
        if !gone {
            return Ok(false);
        }
        let text = cmux_config::jsonc::remove(&text, &path).map_err(settings_error)?;
        tree::write(self.roots(), SETTINGS, text.as_bytes(), false)?;
        Ok(true)
    }
}
