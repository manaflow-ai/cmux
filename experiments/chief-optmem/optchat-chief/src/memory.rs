use std::path::Path;
use crate::paths::Paths;
#[derive(Debug)]
pub struct Report { pub messages: u64 }
pub fn export(_p: &Paths, _out: &Path, _seal: bool) -> Result<Report, String> { todo!("red") }
pub fn import(_p: &Paths, _archive: &Path) -> Result<Report, String> { todo!("red") }
pub fn sealed(_p: &Paths) -> bool { todo!("red") }
