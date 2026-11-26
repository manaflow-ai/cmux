//! Snapshot the inline harness profiles of Classic's `cmux.json` when the
//! person accepts the Mac import, so NEXT never reads Classic's file itself.
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

/// Save the inline profiles that Classic exposed through
/// `$XDG_CONFIG_HOME/cmux/cmux.json`. The confirmed settings merge reads this
/// NEXT-owned map so both relative icons and a non-default XDG root survive.
/// A person editing or removing a profile in NEXT never reimports it at launch.
pub fn import_inline(source: &Path, settings_directory: &Path) -> io::Result<()> {
    let layer = settings_directory.join("classic-harnesses");
    if layer.try_exists()? {
        return Ok(());
    }
    let Some(bytes) = read_file(source, 16 * 1024 * 1024)? else { return Ok(()) };
    let Some(mut doc) =
        std::str::from_utf8(&bytes).ok().and_then(|text| cmux_config::jsonc::parse(text).ok())
    else {
        return Ok(()); // acpmux ignores invalid inline settings too.
    };
    let Some(profiles) =
        doc.pointer_mut("/agents/harnesses").and_then(|value| value.as_object_mut())
    else {
        return Ok(());
    };
    fs::create_dir_all(settings_directory)?;
    let stage =
        tempfile::Builder::new().prefix(".classic-harnesses-").tempdir_in(settings_directory)?;
    let source_dir = source.parent().unwrap_or(Path::new("."));
    for (index, profile) in profiles.values_mut().enumerate() {
        let Some(icon) = profile.get_mut("icon") else { continue };
        if let Some(raw) = icon.as_str()
            && let Some(name) =
                import_icon(raw, source_dir, stage.path(), OsStr::new(&index.to_string()))?
        {
            *icon = serde_json::Value::String(layer.join(name).to_string_lossy().into_owned());
        }
    }
    let output = fs::File::create(stage.path().join("profiles.json"))?;
    serde_json::to_writer(output, &profiles)?;
    match fs::rename(stage.path(), &layer) {
        Err(_) if layer.is_dir() => Ok(()),
        result => result,
    }
}

/// Snapshot file icons as data, leaving validation to the normal loader. A
/// source profile can refer outside its folder, or to a symlink into Classic.
fn import_icon(
    icon: &str,
    source: &Path,
    destination: &Path,
    stem: &OsStr,
) -> io::Result<Option<PathBuf>> {
    let icon = icon.trim();
    let Some(ext) = Path::new(icon).extension().and_then(|ext| ext.to_str()) else {
        return Ok(None);
    };
    if icon.starts_with("sf:")
        || !(ext.eq_ignore_ascii_case("png") || ext.eq_ignore_ascii_case("svg"))
    {
        return Ok(None);
    }
    let icon_path = source.join(icon);
    let mut name = stem.to_owned();
    name.push(format!(".icon.{ext}"));
    if let Some(image) = read_file(&icon_path, 256 * 1024)? {
        install(&destination.join(&name), &image)?;
    }
    Ok(Some(PathBuf::from(name)))
}

fn read_file(path: &Path, limit: u64) -> io::Result<Option<Vec<u8>>> {
    let mut options = fs::File::options();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let meta = file.metadata()?;
    if !meta.is_file() || meta.len() > limit {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    Ok((bytes.len() as u64 <= limit).then_some(bytes))
}

fn install(target: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut tmp = tempfile::NamedTempFile::new_in(target.parent().unwrap_or(Path::new(".")))?;
    tmp.write_all(bytes)?;
    match tmp.persist_noclobber(target) {
        Ok(_) => Ok(()),
        Err(err) if err.error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(err) => Err(err.error),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn imports_jsonc_inline_profiles_and_their_icons_from_an_alternate_xdg_home_once() {
        let root = tempfile::tempdir().unwrap();
        let classic = root.path().join("xdg/cmux");
        let settings = root.path().join("standard/cmux");
        fs::create_dir_all(&classic).unwrap();
        let source = classic.join("cmux.json");
        fs::write(
            &source,
            r#"{// a comment
            "agents":{"harnesses":{"custom":{"command":"launch","icon":"my.svg"},}},}"#,
        )
        .unwrap();
        fs::write(classic.join("my.svg"), "<svg/>").unwrap();
        import_inline(&source, &settings).unwrap();
        let map = settings.join("classic-harnesses/profiles.json");
        let profiles: serde_json::Value = serde_json::from_slice(&fs::read(&map).unwrap()).unwrap();
        let icon = Path::new(profiles["custom"]["icon"].as_str().unwrap());
        assert!(icon.starts_with(settings.join("classic-harnesses")));
        assert_eq!(fs::read_to_string(icon).unwrap(), "<svg/>");
        fs::write(source.clone(), "{}").unwrap();
        import_inline(&source, &settings).unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&fs::read(&map).unwrap()).unwrap(),
            profiles
        );
    }
}
