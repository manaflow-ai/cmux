use super::*;
use crate::tools::Tool;

/// A stand-in for UTType: the extensions the parity tests use.
pub(crate) fn system_kind(name: &str) -> MediaKind {
    match path_extension(name).to_lowercase().as_str() {
        "png" | "jpg" | "jpeg" | "heic" | "gif" | "tiff" => MediaKind::Image,
        "mov" | "mp4" | "m4v" => MediaKind::Video,
        _ => MediaKind::Other,
    }
}

fn kind(rule: &ScanRule, name: &str) -> Option<MediaKind> {
    rule.kind_of_file_named(name, system_kind(name))
}

#[test]
fn quick_time_lists_only_screen_recordings() {
    let rule = Tool::QuickTime.rule();
    assert_eq!(kind(&rule, "Screen Recording 2026-10-19.mov"), Some(MediaKind::Video));
    assert_eq!(kind(&rule, "Holiday.mov"), None);
    assert_eq!(kind(&rule, "Screen Recording.png"), None);
}

#[test]
fn snagit_lists_its_own_format_as_images() {
    assert_eq!(kind(&Tool::Snagit.rule(), "Capture.SNAGX"), Some(MediaKind::Image));
    assert_eq!(kind(&ScanRule::default(), "Capture.snagx"), None);
}

#[test]
fn an_empty_kinds_set_lists_everything() {
    let rule = ScanRule { kinds: 0, ..ScanRule::default() };
    assert_eq!(kind(&rule, "notes.txt"), Some(MediaKind::Other));
    assert_eq!(kind(&rule, ".hidden.png"), None);
}

#[test]
fn folder_prefix_and_hidden_folders() {
    let rule = ScanRule::with_depth(1, Some("media_"));
    assert!(rule.enters_folder("media_123"));
    assert!(!rule.enters_folder("other"));
    assert!(!rule.enters_folder(".media_1"));
    assert!(ScanRule::default().enters_folder("anything"));
}

#[test]
fn prefixes_match_decomposed_names() {
    let rule = ScanRule {
        name_prefixes: vec!["Enregistrement de l’écran".into()],
        ..ScanRule::default()
    };
    let decomposed = "Enregistrement de l’e\u{301}cran 1.mov";
    assert_eq!(kind(&rule, decomposed), Some(MediaKind::Video));
}

#[test]
fn path_extension_matches_nsstring() {
    assert_eq!(path_extension("a.png"), "png");
    assert_eq!(path_extension("a.tar.gz"), "gz");
    assert_eq!(path_extension("noext"), "");
    assert_eq!(path_extension(".bashrc"), "");
    assert_eq!(path_extension("dir/x.MOV"), "MOV");
}
