//! `cmux setup export DIR`: what is live now, written as a setup repo.

use super::*;

impl Customize {
    /// Writes what is live now as a setup repo in `dir` (empty, absent, or a
    /// setup repo already): [`SETUP_FILE`], the files at their logical
    /// paths, and a README with the install line and badge. What a profile
    /// leaves out (credentials, settings only you can change, automations)
    /// it leaves out, and says so.
    pub fn export_setup(
        &self,
        dir: &Path,
        header: &ExportHeader,
        now_ms: u64,
    ) -> Result<Exported, Error> {
        let (owner, _) = header.id.split_once('/').unwrap_or_default();
        check_id(&header.id, owner)?;
        for extension in &header.extensions {
            Reference::parse(extension)?;
        }
        if dir.exists() {
            let empty = std::fs::read_dir(dir)?
                .filter_map(Result::ok)
                .all(|entry| entry.file_name().to_string_lossy().starts_with('.'));
            if !empty && !dir.join(SETUP_FILE).is_file() {
                return Err(Error::Setup(format!(
                    "{} is not empty and is not a setup repo; name a new folder",
                    dir.display()
                )));
            }
        }
        let (profile, mut left_out) =
            self.shareable_profile(&profile_name(&header.id), &header.description, now_ms)?;
        let mut actions = BTreeMap::new();
        let live = settings_text(self)?;
        if let Some(Value::Object(found)) =
            jsonc::parse(&live).ok().and_then(|file| file.get("actions").cloned())
        {
            for (name, value) in found {
                if find_secret(&value.to_string()).is_some() {
                    left_out.push(format!("the action {name}: it looks like it holds a secret"));
                } else if check_actions(&BTreeMap::from([(name.clone(), value.clone())])).is_err() {
                    left_out.push(format!("the action {name}: not one a setup can carry"));
                } else {
                    actions.insert(name, value);
                }
            }
        }
        let repo = if header.repo.is_empty() { header.id.clone() } else { header.repo.clone() };
        let manifest = Manifest {
            format: FORMAT,
            id: header.id.clone(),
            name: header.name.clone(),
            tagline: None,
            description: header.description.clone(),
            version: Some("1.0.0".to_owned()),
            screenshots: Vec::new(),
            engines: Engines::default(),
            extensions: header.extensions.clone(),
            license: None,
            repository: Some(format!("https://github.com/{repo}")),
            profile_format: 1,
            settings: profile.settings.clone(),
            files: BTreeMap::new(),
            actions: actions.clone(),
        };
        std::fs::create_dir_all(dir)?;
        // Exporting again into a setup repo: a file the last export wrote
        // that this one leaves out (one that now holds a credential, a theme
        // you deleted) goes, so the repo is exactly this export.
        if dir.join(SETUP_FILE).is_file() {
            for path in repo_files(dir)?.keys() {
                if !profile.files.contains_key(path) {
                    std::fs::remove_file(dir.join(path))?;
                }
            }
        }
        for (path, text) in &profile.files {
            if path.split('/').any(|piece| piece.is_empty() || piece == "." || piece == "..") {
                continue;
            }
            let file = dir.join(path);
            if let Some(parent) = file.parent() {
                std::fs::create_dir_all(parent)?;
            }
            cmux_config::fsio::write_atomic(&file, text.as_bytes())?;
        }
        let mut text = serde_json::to_string_pretty(&manifest).map_err(std::io::Error::other)?;
        text.push('\n');
        cmux_config::fsio::write_atomic(&dir.join(SETUP_FILE), text.as_bytes())?;
        let readme = dir.join("README.md");
        if !readme.exists() {
            cmux_config::fsio::write_atomic(&readme, readme_text(&manifest, &repo).as_bytes())?;
        }
        Ok(Exported {
            dir: dir.to_path_buf(),
            id: header.id.clone(),
            settings: profile.settings.len(),
            files: profile.files.keys().cloned().collect(),
            actions: actions.keys().cloned().collect(),
            left_out,
            page_url: format!("https://cmux.com/setups/{repo}"),
        })
    }
}

/// The README `export` writes: what it is, how to install it, the badge.
pub fn readme_text(manifest: &Manifest, repo: &str) -> String {
    let mut text = format!(
        "# {}\n\n[![Get it on cmux]({BADGE_URL})](https://cmux.com/setups/{repo})\n\n",
        manifest.name
    );
    if !manifest.description.is_empty() {
        text.push_str(&manifest.description);
        text.push_str("\n\n");
    }
    text.push_str(&format!(
        "A cmux setup: a whole customization in one repo. Install it in one step:\n\n```sh\ncmux setup install github.com/{repo}\n```\n\n`cmux setup remove github.com/{repo}` puts back what you had.\n"
    ));
    if !manifest.extensions.is_empty() {
        text.push_str("\nExtensions it installs:\n\n");
        for extension in &manifest.extensions {
            text.push_str(&format!("- {extension}\n"));
        }
    }
    text
}
