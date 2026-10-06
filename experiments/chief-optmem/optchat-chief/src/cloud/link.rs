use std::path::PathBuf;
use std::sync::Arc;
use crate::daemon::DaemonEvent;
use super::auth::TokenSource;
#[derive(Clone, Debug)]
pub struct CloudLinkConfig { pub socket: PathBuf, pub chief: String, pub conversation: String }
pub fn spawn_cloud_link(_c: CloudLinkConfig, _t: Arc<dyn TokenSource>, _s: Arc<dyn Fn(DaemonEvent) + Send + Sync>, _l: Arc<dyn Fn(&str) + Send + Sync>) { todo!("red") }
