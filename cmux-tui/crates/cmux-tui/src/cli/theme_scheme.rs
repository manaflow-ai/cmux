//! `cmux theme`: 16-color scheme import and export, and a scheme from a
//! background image (extensibility design 12.4, step 13). The converters
//! are `cmux-theme-tokens`' (the daemon's `theme.scheme.*` ops run the same
//! code for pages and extensions); this CLI runs them in process, so it
//! works with cmux quit.
//!
//! - `import FILE [--name N] [--from F] [--replace]`: reads a base16 YAML,
//!   iTerm2 `.itermcolors`, Windows Terminal JSON or Ghostty theme file and
//!   installs it as the Ghostty theme `N` (default: the scheme's own name,
//!   else the file's) in the user's themes folder, where Ghostty and every
//!   cmux theme picker find it. A shipped theme is never shadowed.
//! - `export NAME [--format F] [--output FILE]`: an installed theme as `F`
//!   (default base16), to stdout or FILE.
//! - `convert FILE --to F [--from F] [--output FILE]`: one format to another,
//!   nothing installed.
//! - `from-image PATH [--name N] [--appearance dark|light] [--format F]
//!   [--output FILE] [--replace]`: a scheme from the image's colors, accent
//!   and ANSI held to the theme contrast floors. With `--name` it is
//!   installed; else the file is printed. PNG and binary PPM decode here;
//!   convert other formats (JPEG, HEIC) first.
//! - `formats`: the formats and their names.
//!
//! A file that does not parse exits 1 with `FILE:LINE: what is wrong`.

use std::path::{Path, PathBuf};

use cmux_theme_tokens::{
    Appearance, Env, InstallError, Pixels, Scheme, SchemeFormat, decode_ppm, find_theme_file,
    install_scheme, palette_from_image,
};
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

const USAGE: &str = "\
cmux theme: 16-color schemes in and out of cmux.
  cmux theme import FILE [--name N] [--from F] [--replace]
      install a base16 .yaml, iTerm2 .itermcolors, Windows Terminal .json or Ghostty
      theme as the Ghostty theme N (default: the scheme's name, else the file's)
  cmux theme export NAME [--format F] [--output FILE]   an installed theme as F (default base16)
  cmux theme convert FILE --to F [--from F] [--output FILE]
  cmux theme from-image PATH (PNG or PPM) [--name N] [--appearance dark|light] [--format F] [--output FILE] [--replace]
      a scheme from an image's colors; accent and ANSI keep text readable. --name installs it
  cmux theme formats
Formats: ghostty, base16, iterm2, windows-terminal.";

/// Most bytes of an image `from-image` reads (a 4K PNG wallpaper fits).
const MAX_IMAGE_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
enum Request {
    Import {
        file: PathBuf,
        name: Option<String>,
        from: Option<SchemeFormat>,
        replace: bool,
    },
    Export {
        name: String,
        format: SchemeFormat,
        output: Option<PathBuf>,
    },
    Convert {
        file: PathBuf,
        from: Option<SchemeFormat>,
        to: SchemeFormat,
        output: Option<PathBuf>,
    },
    FromImage {
        path: PathBuf,
        name: Option<String>,
        appearance: Option<Appearance>,
        format: SchemeFormat,
        output: Option<PathBuf>,
        replace: bool,
    },
    Formats,
}

/// `cmux [global options] theme ...`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, words) = super::parse_globals(args).ok()?;
    let rest = words.split_first().filter(|(scope, _)| *scope == "theme").map(|(_, rest)| rest)?;
    let rest: Vec<String> = rest
        .iter()
        .filter(|word| {
            let json = *word == "--json";
            if json {
                global.output = OutputMode::Json;
            }
            !json
        })
        .cloned()
        .collect();
    Some(match parse(&rest) {
        Ok(request) => run(&global, request),
        Err(message) => {
            eprintln!("{message}");
            2
        }
    })
}

fn format_flag(value: Option<&String>, flag: &str) -> Result<SchemeFormat, String> {
    let value = value.ok_or_else(|| format!("{flag} needs a format\n\n{USAGE}"))?;
    SchemeFormat::from_name(value).ok_or_else(|| {
        format!("unknown format {value:?}: one of ghostty, base16, iterm2, windows-terminal")
    })
}

fn parse(args: &[String]) -> Result<Request, String> {
    let usage = || USAGE.to_owned();
    let (verb, rest) = args.split_first().ok_or_else(usage)?;
    let mut positional: Vec<String> = Vec::new();
    let (mut name, mut from, mut to, mut output, mut appearance, mut replace) =
        (None, None, None, None, None, false);
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--name" => name = Some(words.next().ok_or_else(usage)?.clone()),
            "--from" => from = Some(format_flag(words.next(), "--from")?),
            "--to" | "--format" => to = Some(format_flag(words.next(), word)?),
            "--output" | "-o" => output = Some(PathBuf::from(words.next().ok_or_else(usage)?)),
            "--appearance" => {
                appearance = Some(match words.next().map(String::as_str) {
                    Some("dark") => Appearance::Dark,
                    Some("light") => Appearance::Light,
                    _ => return Err(format!("--appearance is dark or light\n\n{USAGE}")),
                });
            }
            "--replace" => replace = true,
            "-h" | "--help" => return Err(usage()),
            flag if flag.starts_with('-') && flag.len() > 1 => {
                return Err(format!("unknown option {flag}\n\n{USAGE}"));
            }
            _ => positional.push(word.clone()),
        }
    }
    let one = |positional: &[String]| match positional {
        [one] => Ok(one.clone()),
        _ => Err(usage()),
    };
    let request = match verb.as_str() {
        "import" if to.is_none() && output.is_none() && appearance.is_none() => {
            Request::Import { file: one(&positional)?.into(), name, from, replace }
        }
        "export" if from.is_none() && name.is_none() && appearance.is_none() && !replace => {
            Request::Export {
                name: one(&positional)?,
                format: to.unwrap_or(SchemeFormat::Base16),
                output,
            }
        }
        "convert" if name.is_none() && appearance.is_none() && !replace => Request::Convert {
            file: one(&positional)?.into(),
            from,
            to: to.ok_or_else(|| format!("convert needs --to FORMAT\n\n{USAGE}"))?,
            output,
        },
        "from-image" if from.is_none() => Request::FromImage {
            path: one(&positional)?.into(),
            name,
            appearance,
            format: to.unwrap_or(SchemeFormat::Ghostty),
            output,
            replace,
        },
        "formats" if positional.is_empty() && rest.is_empty() => Request::Formats,
        _ => return Err(usage()),
    };
    Ok(request)
}

fn fail(global: &GlobalArgs, code: &str, message: String) -> i32 {
    super::wire::print_local_error(&json!({ "code": code, "message": message }), global.output, 1)
}

fn read_scheme(file: &Path, from: Option<SchemeFormat>) -> Result<Scheme, (String, String)> {
    let shown = file.display().to_string();
    let size =
        std::fs::metadata(file).map_err(|e| ("io".to_owned(), format!("{shown}: {e}")))?.len();
    if size > cmux_theme_tokens::MAX_SCHEME_BYTES as u64 {
        return Err(("validation.invalid".into(), format!("{shown}: larger than a scheme file")));
    }
    let text =
        std::fs::read_to_string(file).map_err(|e| ("io".to_owned(), format!("{shown}: {e}")))?;
    Scheme::parse(&text, &shown, from).map_err(|e| ("validation.invalid".to_owned(), e.to_string()))
}

/// The name an imported file gets: the scheme's own, else the file's
/// without a scheme extension.
fn default_name(scheme: &Scheme, file: &Path) -> String {
    if let Some(name) = scheme.name.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
        return name.to_owned();
    }
    let stem = match file.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase) {
        Some(ext)
            if ["yaml", "yml", "itermcolors", "json", "conf", "theme"].contains(&ext.as_str()) =>
        {
            file.file_stem()
        }
        _ => file.file_name(),
    };
    stem.map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

fn install(global: &GlobalArgs, name: &str, scheme: &Scheme, replace: bool, extra: Value) -> i32 {
    match install_scheme(&Env::current(), name, scheme, replace) {
        Ok(path) => {
            let mut value = json!({
                "name": name,
                "path": path.display().to_string(),
                "message": format!("installed theme {name:?}; pick it in Settings > Theme, or set theme = {name}"),
            });
            if let (Some(obj), Value::Object(more)) = (value.as_object_mut(), extra) {
                obj.extend(more);
            }
            super::wire::print_local_success(&value, global.output)
        }
        Err(error @ InstallError::InvalidName) => {
            fail(global, "validation.invalid", format!("{name:?}: {error}"))
        }
        Err(error @ (InstallError::Exists(_) | InstallError::ShippedName(_))) => {
            fail(global, "theme.exists", error.to_string())
        }
        Err(error) => fail(global, "io", error.to_string()),
    }
}

/// Writes `text` to `output`, or prints it (raw in text mode, so `> file` works).
fn emit(global: &GlobalArgs, text: &str, output: Option<&Path>, extra: Value) -> i32 {
    if let Some(output) = output {
        if let Err(error) = std::fs::write(output, text) {
            return fail(global, "io", format!("{}: {error}", output.display()));
        }
        let mut value = json!({ "path": output.display().to_string() });
        if let (Some(obj), Value::Object(more)) = (value.as_object_mut(), extra) {
            obj.extend(more);
        }
        return super::wire::print_local_success(&value, global.output);
    }
    if matches!(global.output, OutputMode::Json | OutputMode::JsonLines) {
        let mut value = json!({ "text": text });
        if let (Some(obj), Value::Object(more)) = (value.as_object_mut(), extra) {
            obj.extend(more);
        }
        return super::wire::print_local_success(&value, global.output);
    }
    use std::io::Write as _;
    let mut stdout = std::io::stdout().lock();
    match stdout.write_all(text.as_bytes()).and_then(|()| stdout.flush()) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

fn run(global: &GlobalArgs, request: Request) -> i32 {
    match request {
        Request::Formats => {
            let formats: Vec<Value> = SchemeFormat::ALL
                .iter()
                .map(|f| json!({ "name": f.name(), "extension": f.extension() }))
                .collect();
            if matches!(global.output, OutputMode::Json | OutputMode::JsonLines) {
                return super::wire::print_local_success(
                    &json!({ "formats": formats }),
                    global.output,
                );
            }
            for f in SchemeFormat::ALL {
                let ext = if f.extension().is_empty() {
                    "(no extension)".to_owned()
                } else {
                    format!(".{}", f.extension())
                };
                println!("{:<18}{ext}", f.name());
            }
            0
        }
        Request::Import { file, name, from, replace } => match read_scheme(&file, from) {
            Ok(scheme) => {
                let name = name.unwrap_or_else(|| default_name(&scheme, &file));
                install(global, &name, &scheme, replace, json!({}))
            }
            Err((code, message)) => fail(global, &code, message),
        },
        Request::Convert { file, from, to, output } => match read_scheme(&file, from) {
            Ok(scheme) => {
                emit(global, &scheme.export(to), output.as_deref(), json!({ "format": to.name() }))
            }
            Err((code, message)) => fail(global, &code, message),
        },
        Request::Export { name, format, output } => {
            let Some(path) = find_theme_file(&Env::current(), &name) else {
                return fail(
                    global,
                    "resource.not_found",
                    format!("no installed theme named {name:?}"),
                );
            };
            match read_scheme(&path, Some(SchemeFormat::Ghostty)) {
                Ok(mut scheme) => {
                    scheme.name = Some(name.clone());
                    emit(
                        global,
                        &scheme.export(format),
                        output.as_deref(),
                        json!({ "name": name, "format": format.name() }),
                    )
                }
                Err((code, message)) => fail(global, &code, message),
            }
        }
        Request::FromImage { path, name, appearance, format, output, replace } => {
            let (width, height, channels, data) = match decode_image(&path) {
                Ok(decoded) => decoded,
                Err(message) => return fail(global, "validation.invalid", message),
            };
            let pixels = Pixels { width, height, channels, data: &data };
            let palette = match palette_from_image(&pixels, appearance) {
                Ok(palette) => palette,
                Err(error) => {
                    return fail(
                        global,
                        "validation.invalid",
                        format!("{}: {error}", path.display()),
                    );
                }
            };
            let extra = json!({
                "appearance": if palette.appearance == Appearance::Dark { "dark" } else { "light" },
                "accent": format!("#{:06x}", palette.accent.to_hex()),
                "glassTint": format!("#{:08x}", palette.glass_tint.to_rgba_u32()),
            });
            match name {
                Some(name) => install(global, &name, &palette.scheme, replace, extra),
                None => {
                    let mut scheme = palette.scheme;
                    scheme.name = path.file_stem().map(|s| s.to_string_lossy().into_owned());
                    emit(global, &scheme.export(format), output.as_deref(), extra)
                }
            }
        }
    }
}

/// The image's pixels: PNG and binary PPM (other formats: convert first).
fn decode_image(path: &Path) -> Result<(u32, u32, u8, Vec<u8>), String> {
    let shown = path.display();
    let size = std::fs::metadata(path).map_err(|e| format!("{shown}: {e}"))?.len();
    if size > MAX_IMAGE_BYTES {
        return Err(format!("{shown}: larger than {MAX_IMAGE_BYTES} bytes"));
    }
    let bytes = std::fs::read(path).map_err(|e| format!("{shown}: {e}"))?;
    if bytes.starts_with(b"P6") {
        let (w, h, data) = decode_ppm(&bytes).map_err(|e| format!("{shown}: {e}"))?;
        return Ok((w, h, 3, data));
    }
    if bytes.starts_with(b"\x89PNG") {
        return decode_png(&bytes).map_err(|e| format!("{shown}: {e}"));
    }
    Err(format!(
        "{shown}: only PNG and binary PPM are read; convert it first (e.g. `sips -s format png IMAGE --out out.png` or `magick IMAGE out.png`)"
    ))
}

fn decode_png(bytes: &[u8]) -> Result<(u32, u32, u8, Vec<u8>), String> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    // 8-bit RGB(A) out of every PNG color type and depth.
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().map_err(|e| format!("not a readable PNG: {e}"))?;
    let mut buffer = vec![0; reader.output_buffer_size()];
    let frame = reader.next_frame(&mut buffer).map_err(|e| format!("not a readable PNG: {e}"))?;
    let channels: u8 = match frame.color_type {
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        png::ColorType::Grayscale => 1,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Indexed => return Err("an indexed PNG the decoder did not expand".into()),
    };
    buffer.truncate(frame.buffer_size());
    // Gray to RGB(A), so the palette reads 3 or 4 channels.
    let data = match channels {
        1 => buffer.iter().flat_map(|g| [*g, *g, *g]).collect(),
        2 => buffer
            .chunks_exact(2)
            .flat_map(|p| match p {
                [g, a] => [*g, *g, *g, *a],
                _ => [0, 0, 0, 0],
            })
            .collect(),
        _ => buffer,
    };
    let out_channels = if channels == 2 || channels == 4 { 4 } else { 3 };
    Ok((frame.width, frame.height, out_channels, data))
}

#[cfg(test)]
mod tests;
