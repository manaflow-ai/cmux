use super::*;

fn fields(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

const BASE16: &str = "scheme: \"T\"\nbase00: \"1d1f21\"\nbase01: \"282a2e\"\nbase02: \"373b41\"\nbase03: \"969896\"\nbase04: \"b4b7b4\"\nbase05: \"c5c8c6\"\nbase06: \"e0e0e0\"\nbase07: \"ffffff\"\nbase08: \"cc6666\"\nbase09: \"de935f\"\nbase0A: \"f0c674\"\nbase0B: \"b5bd68\"\nbase0C: \"8abeb7\"\nbase0D: \"81a2be\"\nbase0E: \"b294bb\"\nbase0F: \"a3685a\"\n";

#[test]
fn convert_reads_base16_and_writes_ghostty() {
    let out = convert(&fields(json!({ "text": BASE16, "file": "t.yaml" }))).unwrap();
    assert_eq!(out["from"], "base16");
    assert_eq!(out["format"], "ghostty");
    assert_eq!(out["scheme"]["background"], "#1d1f21");
    assert_eq!(out["scheme"]["palette"][4], "#81a2be");
    assert!(out["text"].as_str().unwrap().contains("palette = 4=#81a2be"));
}

#[test]
fn convert_names_the_file_and_line_of_a_bad_color() {
    let bad = BASE16.replace("\"b294bb\"", "\"b294zz\"");
    let error = convert(&fields(json!({ "text": bad, "file": "t.yaml" }))).unwrap_err();
    assert_eq!(error.code, "validation.invalid");
    assert!(error.message.contains("t.yaml:15"), "{}", error.message);
}

#[test]
fn export_reads_an_installed_theme_by_name() {
    let home = std::env::temp_dir().join(format!("cmux-core-theme-export-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let env =
        Env { home: Some(home.clone()), xdg_data_dirs: Some(String::new()), ..Env::default() };
    let scheme = Scheme::parse(BASE16, "t.yaml", None).unwrap();
    cmux_theme_tokens::install_scheme(&env, "Mine", &scheme, false).unwrap();
    let out = export(&fields(json!({ "name": "Mine", "format": "base16" })), &env).unwrap();
    assert!(out["text"].as_str().unwrap().contains("base0D: \"#81a2be\""), "{out}");
    assert!(export(&fields(json!({ "name": "../etc/passwd" })), &env).is_err());
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn from_image_gives_a_readable_scheme() {
    let mut data = Vec::new();
    for i in 0..64u32 {
        data.extend_from_slice(if i < 40 { &[16, 24, 48] } else { &[120, 60, 20] });
    }
    let pixels = base64::engine::general_purpose::STANDARD.encode(&data);
    let out = from_image(&fields(json!({
        "width": 8, "height": 8, "channels": 3, "pixels": pixels,
    })))
    .unwrap();
    assert_eq!(out["appearance"], "dark");
    assert!(out["accent"].as_str().unwrap().starts_with('#'));
    let too_big = from_image(&fields(json!({
        "width": 1000, "height": 1000, "channels": 3, "pixels": "",
    })));
    assert!(too_big.is_err());
}
