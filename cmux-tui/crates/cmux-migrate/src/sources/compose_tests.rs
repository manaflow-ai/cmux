use std::path::Path;

use super::*;
use crate::sources::project_files::ENSURE_DOCKER;

fn write(root: &Path, path: &str, text: &str) {
    let path = root.join(path);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

const COMPOSE: &str = r#"
services:
  web:
    build: .
    ports:
      - "8080:3000"
      - 9229
    environment:
      NODE_ENV: development
      DATABASE_URL: postgres://app:planted-db-pass@db:5432/app
      STRIPE_SECRET_KEY: sk_live_planted_value
      SESSION_TOKEN: planted-token
      LOG_LEVEL: ${LOG_LEVEL:-info}
      FROM_HOST:
    env_file:
      - .env.local
      - missing.env
    volumes:
      - .:/app
  db:
    image: postgres:16
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    ports:
      - target: 5432
        published: "5433"
  redis:
    image: redis:7
    ports: ["127.0.0.1:6379:6379"]
  docs:
    image: nginx
    profiles: [docs]
"#;

#[test]
fn the_built_service_is_the_project_and_the_rest_are_sidecars() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), "docker-compose.yml", COMPOSE);
    write(dir.path(), ".env.local", "# local\nexport API_KEY=planted-env-file-value\nREGION=eu\n");
    let plan = plan(dir.path());
    assert_eq!(plan.source.kind, SourceKind::Compose);
    assert_eq!(plan.projects.len(), 1, "{:?}", plan.warnings);
    let p = &plan.projects[0];
    assert_eq!(p.key, "docker-compose.yml");
    assert_eq!(p.services, vec!["db".to_owned(), "redis".to_owned()]);
    assert_eq!(p.ports, vec![3000, 9229, 5433, 6379]);
    let setup = &p.machine.setup;
    assert_eq!(setup[0], ENSURE_DOCKER);
    assert!(setup.contains(&"docker compose -f docker-compose.yml build web".to_owned()));
    assert_eq!(
        setup.last().map(String::as_str),
        Some("docker compose -f docker-compose.yml up -d db redis")
    );

    let env = &p.machine.env;
    assert_eq!(env.get("NODE_ENV").map(String::as_str), Some("development"));
    assert_eq!(env.get("LOG_LEVEL").map(String::as_str), Some("${LOG_LEVEL:-info}"));
    let secrets = &p.machine.secret_names;
    for name in [
        "DATABASE_URL",
        "STRIPE_SECRET_KEY",
        "SESSION_TOKEN",
        "FROM_HOST",
        "API_KEY",
        "REGION",
        "LOG_LEVEL",
    ] {
        assert!(secrets.contains(name), "{name} in {secrets:?}");
    }
    assert!(!env.contains_key("DATABASE_URL") && !env.contains_key("SESSION_TOKEN"));
    assert!(p.notes.iter().any(|n| n.contains("missing.env")));
    assert!(p.notes.iter().any(|n| n.contains("docs") && n.contains("profile")));
    assert!(plan.warnings.iter().any(|w| w.contains("POSTGRES_PASSWORD")));
    assert!(plan.unsupported.iter().any(|u| u.what == "web: volumes"));

    // No planted value reaches the plan or the machine file.
    let json = serde_json::to_string(&plan).unwrap();
    let toml = crate::machine_toml::render(&p.machine);
    for planted in
        ["planted-db-pass", "sk_live_planted_value", "planted-token", "planted-env-file-value"]
    {
        assert!(!json.contains(planted), "{planted} in plan");
        assert!(!toml.contains(planted), "{planted} in machine.toml");
    }
}

#[test]
fn without_a_built_service_every_service_is_a_sidecar() {
    let dir = tempfile::tempdir().unwrap();
    write(
        dir.path(),
        "compose.yaml",
        "services:\n  db:\n    image: postgres\n    ports: [\"5432:5432\"]\n",
    );
    let p = project(dir.path()).unwrap();
    assert_eq!(p.services, vec!["db".to_owned()]);
    assert_eq!(p.ports, vec![5432]);
    assert!(p.image.is_none());
    assert_eq!(
        p.machine.setup,
        vec![ENSURE_DOCKER.to_owned(), "docker compose -f compose.yaml up -d db".to_owned()]
    );
}

#[test]
fn compose_yaml_wins_over_docker_compose_yml() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), "docker-compose.yml", "services:\n  a:\n    image: x\n");
    write(dir.path(), "compose.yaml", "services:\n  b:\n    image: y\n");
    assert_eq!(project(dir.path()).unwrap().services, vec!["b".to_owned()]);
}

#[test]
fn bad_yaml_and_missing_files_warn() {
    let dir = tempfile::tempdir().unwrap();
    assert!(project(dir.path()).is_none());
    write(dir.path(), "compose.yml", "services: [unclosed\n");
    assert!(project(dir.path()).is_none());
    let plan = plan(dir.path());
    assert!(plan.projects.is_empty());
    assert!(plan.warnings[0].contains("compose.yml"));
}

#[test]
fn a_named_service_that_is_absent_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), "compose.yml", "services:\n  a:\n    image: x\n");
    let file = dir.path().join("compose.yml");
    assert!(read_files(dir.path(), &[file], Some("nope"), None).is_err());
}
