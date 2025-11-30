#[derive(Clone, Debug)]
pub enum WorkspaceSyncStatus {
    InProgress,
    Completed,
    Failed(String),
}
