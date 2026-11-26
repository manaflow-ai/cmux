use std::path::Path;

use super::*;

fn write(root: &Path, path: &str, text: &str) {
    let full = root.join(path);
    std::fs::create_dir_all(full.parent().unwrap()).unwrap();
    std::fs::write(full, text).unwrap();
}

#[test]
fn env_example_keys_become_secret_names_and_a_real_env_is_not_read() {
    let dir = tempfile::tempdir().unwrap();
    write(
        dir.path(),
        ".env.example",
        "DATABASE_URL=postgres://u:planted-example@h/db\n# c\nSTRIPE_KEY=\n",
    );
    write(dir.path(), ".env", "REAL_ONLY=planted-real-value\n");
    let r = read(dir.path());
    let names: Vec<&String> = r.names.keys().collect();
    assert_eq!(names, vec!["DATABASE_URL", "STRIPE_KEY"]);
    assert!(
        r.notes
            .iter()
            .any(|n| n.contains(".env.example") && n.contains("cmux cloud secret set NAME"))
    );
    assert!(r.notes.iter().any(|n| n.contains(".env holds real values and was not read")));
    let text = format!("{r:?}");
    assert!(!text.contains("planted-real-value") && !text.contains("REAL_ONLY"));
    assert!(!text.contains("planted-example"));
}

#[test]
fn one_password_refs_name_secrets_without_resolving_them() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), ".env.tpl", "API_KEY=op://Private/Stripe/credential\n");
    write(dir.path(), "config.yml.tpl", "token: {{ op://Dev/GitHub/pat }}\n");
    let r = read(dir.path());
    assert!(r.names["API_KEY"].contains("op://Private/Stripe/credential"));
    assert!(r.names.contains_key("PAT"));
}

#[test]
fn vault_aws_doppler_and_infisical_are_referenced() {
    let dir = tempfile::tempdir().unwrap();
    write(
        dir.path(),
        "scripts/fetch.sh",
        "export VAULT_ADDR=https://v.example\nvault kv get -field=password secret/app/db\n\
         aws secretsmanager get-secret-value --secret-id prod/app/stripe --query SecretString\n\
         aws ssm get-parameter --name /app/prod/SENDGRID_KEY --with-decryption\n",
    );
    write(dir.path(), "doppler.yaml", "setup:\n  project: api\n  config: prd\n");
    write(
        dir.path(),
        ".infisical.json",
        "{\"workspaceId\":\"abc\",\"defaultEnvironment\":\"dev\"}",
    );
    let r = read(dir.path());
    for name in ["VAULT_ADDR", "PASSWORD", "STRIPE", "SENDGRID_KEY"] {
        assert!(r.names.contains_key(name), "{name} in {:?}", r.names);
    }
    assert!(r.notes.iter().any(|n| n.contains("Doppler") && n.contains("project api")));
    assert!(r.notes.iter().any(|n| n.contains("Infisical")));
}

#[test]
fn merged_plan_json_holds_names_only() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), ".env.example", "SECRET_TOKEN=planted-token-1\n");
    write(dir.path(), ".env.local", "OTHER=planted-local-2\n");
    write(dir.path(), ".env.op", "GH=op://v/i/f\n");
    let mut plan = crate::Plan::new(super::super::project_files::checkout_source(
        crate::SourceKind::Compose,
        dir.path(),
    ));
    assert!(super::super::merge_ci_and_secrets(dir.path(), &mut plan));
    let secrets = &plan.projects[0].machine.secret_names;
    assert!(secrets.contains("SECRET_TOKEN") && secrets.contains("GH"));
    let json = serde_json::to_string(&plan).unwrap();
    assert!(!json.contains("planted-token-1") && !json.contains("planted-local-2"));
}
