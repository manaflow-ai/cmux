use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

#[test]
fn parses_each_verb() {
    assert_eq!(
        parse(&args(&["import", "x.yaml", "--name", "Mine", "--replace"])).unwrap(),
        Request::Import {
            file: "x.yaml".into(),
            name: Some("Mine".into()),
            from: None,
            replace: true
        }
    );
    assert_eq!(
        parse(&args(&["export", "Nord", "--format", "iterm2"])).unwrap(),
        Request::Export { name: "Nord".into(), format: SchemeFormat::Iterm2, output: None }
    );
    assert_eq!(
        parse(&args(&["export", "Nord"])).unwrap(),
        Request::Export { name: "Nord".into(), format: SchemeFormat::Base16, output: None }
    );
    assert!(matches!(
        parse(&args(&["from-image", "w.png", "--appearance", "light"])).unwrap(),
        Request::FromImage {
            appearance: Some(Appearance::Light),
            format: SchemeFormat::Ghostty,
            ..
        }
    ));
    assert!(parse(&args(&["convert", "x.yaml"])).is_err(), "convert needs --to");
    assert!(parse(&args(&["export", "Nord", "--format", "png"])).is_err());
    assert!(parse(&args(&["import"])).is_err());
    assert!(parse(&args(&["nope"])).is_err());
}

#[test]
fn a_vscode_theme_imports_as_a_scheme_not_a_cmux_theme_file() {
    assert_eq!(
        parse(&args(&["convert", "t.json", "--from", "vscode", "--to", "ghostty"])).unwrap(),
        Request::Convert {
            file: "t.json".into(),
            from: Some(SchemeFormat::VsCode),
            to: SchemeFormat::Ghostty,
            output: None
        }
    );
    assert!(USAGE.contains("VS Code"));
    let dir = tempfile::tempdir().unwrap();
    // `name` and `colors` are a cmux theme file's keys too: the dotted
    // VS Code color keys send it to the scheme importer.
    let vscode = dir.path().join("harbor.json");
    std::fs::write(
        &vscode,
        "// comment\n{\"name\": \"Harbor\", \"colors\": {\"editor.background\": \"#101010\",},}\n",
    )
    .unwrap();
    let file = vscode.to_string_lossy().into_owned();
    assert!(theme_file_request(&args(&["import", &file])).is_none());
    let Request::Import { file, from, .. } = parse(&args(&["import", &file])).unwrap() else {
        panic!("not an import");
    };
    assert_eq!(from, None);
    let scheme = read_scheme(&file, None).unwrap();
    assert_eq!(scheme.background.to_hex(), 0x101010);
    assert_eq!(default_name(&scheme, &file), "Harbor");
}

#[test]
fn an_imported_file_is_named_by_its_scheme_then_its_file() {
    let mut scheme = Scheme::from_theme_input(&cmux_theme_tokens::ThemeInput::GHOSTTY_DEFAULT);
    assert_eq!(default_name(&scheme, Path::new("/x/tokyo-night.yaml")), "tokyo-night");
    assert_eq!(default_name(&scheme, Path::new("/x/Nord")), "Nord");
    scheme.name = Some("Tokyo Night".into());
    assert_eq!(default_name(&scheme, Path::new("/x/tokyo-night.yaml")), "Tokyo Night");
}

#[test]
fn a_png_decodes_to_rgb() {
    let mut bytes = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut bytes, 2, 1);
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(&[1, 2, 3, 4, 5, 6]).unwrap();
    }
    assert_eq!(decode_png(&bytes).unwrap(), (2, 1, 3, vec![1, 2, 3, 4, 5, 6]));
}
