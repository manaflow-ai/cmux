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
    // BASE16 is `scheme:` on line 1, then base00..base0F on lines 2..17 (1-based),
    // so the bad base0E is on line 16.
    assert!(error.message.starts_with("t.yaml:16: base0E"), "{}", error.message);
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
fn resolve_slots_keeps_shipped_variants_and_names_the_rest() {
    let text = r#"{
  "appearance.accent": "not-a-color-name",
  "slots": { "chat.thinkingIndicator": "pulse", "chat.jumpToBottom": "spin", "chat.x": "default" }
}"#;
    let out = resolve_slots(&fields(json!({ "text": text, "name": "pack" }))).unwrap();
    assert_eq!(out["slots"], json!({ "chat.thinkingIndicator": "pulse" }));
    let diagnostics = out["diagnostics"].as_array().unwrap();
    // Only the slots' problems: the accent is the settings reader's business.
    assert_eq!(diagnostics.len(), 2, "{out}");
    assert_eq!(diagnostics[0]["path"], "slots.chat.jumpToBottom");
    assert_eq!(diagnostics[0]["kind"], "invalid_value");
    assert!(diagnostics[0]["message"].as_str().unwrap().starts_with("themes/pack.json:3: "));
    assert_eq!(diagnostics[1]["path"], "slots.chat.x");

    let none = resolve_slots(&fields(json!({ "text": "{}" }))).unwrap();
    assert_eq!(
        none,
        json!({
            "slots": {},
            "motion": { "presets": {}, "springs": {}, "fades": {} },
            "diagnostics": [],
        })
    );
    let broken = resolve_slots(&fields(json!({ "text": "{ \"slots\": " }))).unwrap();
    assert_eq!(broken["slots"], json!({}));
    assert_eq!(broken["diagnostics"][0]["kind"], "unreadable_file");
    let garbage = resolve_slots(&fields(json!({ "text": "{ \"slots\": [1, 2] }" }))).unwrap();
    assert_eq!(garbage["slots"], json!({}));
    assert_eq!(garbage["diagnostics"][0]["path"], "slots");
    assert!(resolve_slots(&fields(json!({}))).is_err());
}

#[test]
fn resolve_slots_answers_the_looks_motion_and_its_problems() {
    let text = r#"{
  "motion": {
    "presets": { "drawer": { "duration": 0.32, "bounce": 0.1 } },
    "springs": { "move": { "duration": 99 }, "wobble": { "duration": 0.2 } },
    "fades": { "fadeIn": 0.16 }
  }
}"#;
    let out = resolve_slots(&fields(json!({ "text": text }))).unwrap();
    let motion = &out["motion"];
    assert_eq!(motion["presets"]["drawer"]["response"], json!(0.32));
    assert_eq!(motion["presets"]["drawer"]["dampingFraction"], json!(0.9));
    assert_eq!(motion["springs"]["move"]["duration"], json!(10.0), "clamped to cmux.motion/1");
    assert!(motion["springs"].get("wobble").is_none());
    assert_eq!(motion["fades"]["fadeIn"], json!(0.16));
    let paths: Vec<&str> =
        out["diagnostics"].as_array().unwrap().iter().filter_map(|d| d["path"].as_str()).collect();
    assert_eq!(paths, ["motion.springs.wobble"]);
    // A reload is a new read of the new text: the edited block replaces the old one.
    let edited = resolve_slots(&fields(
        json!({ "text": r#"{ "motion": { "fades": { "fadeIn": 0.3 } } }"# }),
    ))
    .unwrap();
    assert_eq!(edited["motion"]["presets"], json!({}));
    assert_eq!(edited["motion"]["fades"]["fadeIn"], json!(0.3));
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
