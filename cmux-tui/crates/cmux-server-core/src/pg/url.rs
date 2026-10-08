//! Connection settings an app gets (server.md 8.3): `PGHOST`, `PGPORT`,
//! `PGDATABASE`, `PGUSER` and `DATABASE_URL`, never with a password. In user
//! mode the password reaches libpq only through `PGPASSFILE`.

use super::{AppDb, PgPlan};

/// Percent-encodes everything but RFC 3986 unreserved characters and `/`.
fn encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

impl PgPlan {
    /// The host an app connects to: the socket directory, or `127.0.0.1`
    /// when the app uses TCP (and on Windows).
    pub fn app_host(&self, app: &AppDb) -> String {
        if app.tcp || !self.uses_socket() {
            "127.0.0.1".to_owned()
        } else {
            self.spec().socket_dir.to_string()
        }
    }

    /// `DATABASE_URL` without a password: `postgresql://<role>@/<db>?host=
    /// <socket dir>&port=<port>` for a Unix socket, else
    /// `postgresql://<role>@127.0.0.1:<port>/<db>`.
    pub fn database_url(&self, app: &AppDb) -> String {
        let role = app.id.role();
        let db = encode(&app.database());
        let port = self.spec().port;
        if app.tcp || !self.uses_socket() {
            format!("postgresql://{role}@127.0.0.1:{port}/{db}")
        } else {
            let host = encode(self.spec().socket_dir.as_str());
            format!("postgresql://{role}@/{db}?host={host}&port={port}")
        }
    }

    /// `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `DATABASE_URL` for the app
    /// service (server.md 7.4); `PGPASSFILE` is added by the caller in user
    /// mode, because only the caller knows the app's state directory.
    pub fn app_env(&self, app: &AppDb) -> Vec<(&'static str, String)> {
        vec![
            ("PGHOST", self.app_host(app)),
            ("PGPORT", self.spec().port.to_string()),
            ("PGDATABASE", app.database()),
            ("PGUSER", app.id.role()),
            ("DATABASE_URL", self.database_url(app)),
        ]
    }
}
