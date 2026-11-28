//! File names the pane makes: a dropped image's name and a rename's target (Swift
//! `ScreenshotDropSaver.droppedName`, `ScreenshotsCommands.rename`).

/// The name of an image dropped as data, from the local time it was saved:
/// `Dropped Image 2026-11-26 at 09.05.03.png` (Gregorian, 24-hour, as macOS names screenshots).
pub fn dropped_name(
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
) -> String {
    format!("Dropped Image {year:04}-{month:02}-{day:02} at {hour:02}.{minute:02}.{second:02}.png")
}

/// The name a rename gives the file: the typed name trimmed, or None when that is the current
/// name (nothing to do).
pub fn rename_target(current: &str, typed: &str) -> Option<String> {
    let trimmed = typed.trim();
    (trimmed != current).then(|| trimmed.to_owned())
}

#[cfg(test)]
#[path = "names_tests.rs"]
mod tests;
