//! The rules behind the cmux NEXT app's History, Search All Windows, file
//! explorer, Find and window hints (`Packages/macOS/CmuxNext/Sources/CmuxNextApp/
//! {History,GlobalSearch,FileExplorer,Hints}`). Pure: the app reads its
//! daemons, files and views, sends the facts and acts on the answer.

pub mod commands;
pub mod files;
pub mod find;
pub mod hints;
pub mod retention;
pub mod search;
