use std::path::Path;

use super::*;

fn write(root: &Path, path: &str, text: &str) {
    let full = root.join(path);
    std::fs::create_dir_all(full.parent().unwrap()).unwrap();
    std::fs::write(full, text).unwrap();
}

const GITHUB: &str = r#"
name: ci
on: [push]
env:
  STRIPE_SECRET_KEY: sk_live_planted_value
  LOG_LEVEL: debug
jobs:
  test:
    runs-on: ubuntu-latest
    container: node:20-bookworm
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: planted-pg-password
      redis:
        image: redis:7
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: |
          sudo apt-get install -y libpq-dev jq
          pip install -r requirements.txt
          export API_TOKEN=planted-token-value
      - run: npm test
        env:
          DEPLOY_KEY: ${{ secrets.DEPLOY_KEY }}
      - run: ./deploy.sh ${{ secrets.NPM_TOKEN }} ${{ secrets.GITHUB_TOKEN }}
"#;

#[test]
fn a_github_workflow_gives_image_setup_checks_services_and_secret_names() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), ".github/workflows/ci.yml", GITHUB);
    let r = read(dir.path());
    assert_eq!(r.image.as_deref(), Some("node:20-bookworm"));
    assert!(r.setup.contains(&"npm ci".to_owned()), "{:?}", r.setup);
    assert!(r.setup.contains(&"pip install -r requirements.txt".to_owned()));
    assert!(r.setup.iter().any(|s| s.contains("apt-get install -y -qq libpq-dev jq")));
    assert_eq!(r.check, vec!["npm test"]);
    assert_eq!(r.services, vec!["postgres", "redis"]);
    for name in ["DEPLOY_KEY", "NPM_TOKEN", "STRIPE_SECRET_KEY"] {
        assert!(r.secret_names.contains(&name.to_owned()), "{name} in {:?}", r.secret_names);
    }
    assert!(!r.secret_names.contains(&"GITHUB_TOKEN".to_owned()));
    assert!(!r.setup.iter().any(|s| s.contains("API_TOKEN")));
}

#[test]
fn ci_findings_merge_into_the_project_without_values() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), ".github/workflows/ci.yml", GITHUB);
    let mut plan = crate::Plan::new(super::super::project_files::checkout_source(
        crate::SourceKind::Nix,
        dir.path(),
    ));
    assert!(super::super::merge_ci_and_secrets(dir.path(), &mut plan));
    assert_eq!(plan.projects.len(), 1);
    let p = &plan.projects[0];
    assert_eq!(p.image.as_deref(), Some("node:20-bookworm"));
    assert_eq!(p.services, vec!["postgres", "redis"]);
    let json = serde_json::to_string(&plan).unwrap();
    for planted in ["sk_live_planted_value", "planted-pg-password", "planted-token-value"] {
        assert!(!json.contains(planted), "{planted} leaked");
    }
}

#[test]
fn a_gitlab_file_gives_image_services_and_variable_names() {
    let dir = tempfile::tempdir().unwrap();
    write(
        dir.path(),
        ".gitlab-ci.yml",
        r#"
image: ruby:3.3
services:
  - postgres:16
variables:
  DATABASE_PASSWORD: planted-gitlab-password
  RAILS_ENV: test
test:
  before_script:
    - bundle install
  script:
    - 'curl -H "Authorization: $DEPLOY_TOKEN" https://example.com'
    - bundle exec rspec
"#,
    );
    let r = read(dir.path());
    assert_eq!(r.image.as_deref(), Some("ruby:3.3"));
    assert_eq!(r.services, vec!["postgres"]);
    assert_eq!(r.setup, vec!["bundle install"]);
    assert_eq!(r.check, vec!["bundle exec rspec"]);
    assert_eq!(r.secret_names, vec!["DATABASE_PASSWORD", "DEPLOY_TOKEN"]);
    assert!(!format!("{r:?}").contains("planted-gitlab-password"));
}

#[test]
fn circleci_and_bitbucket_are_read() {
    let dir = tempfile::tempdir().unwrap();
    write(
        dir.path(),
        ".circleci/config.yml",
        r#"
jobs:
  build:
    docker:
      - image: cimg/python:3.12
      - image: cimg/postgres:16.0
    steps:
      - run:
          name: deps
          command: pip install -r requirements.txt
      - run: pytest
workflows:
  main:
    jobs:
      - build:
          context: [prod-secrets]
"#,
    );
    write(
        dir.path(),
        "bitbucket-pipelines.yml",
        "image: node:18\npipelines:\n  default:\n    - step:\n        script:\n          - yarn install\n          - yarn test\n",
    );
    let r = read(dir.path());
    assert_eq!(r.image.as_deref(), Some("cimg/python:3.12"));
    assert_eq!(r.services, vec!["postgres"]);
    assert_eq!(r.setup, vec!["pip install -r requirements.txt", "yarn install"]);
    assert_eq!(r.check, vec!["pytest", "yarn test"]);
    assert!(r.notes.iter().any(|n| n.contains("prod-secrets")));
}

#[test]
fn setup_is_deduplicated_and_capped() {
    let dir = tempfile::tempdir().unwrap();
    let mut steps = String::from("jobs:\n  a:\n    steps:\n");
    for i in 0..30 {
        steps
            .push_str(&format!("      - run: pip install pkg{i}\n      - run: pip install pkg0\n"));
    }
    write(dir.path(), ".github/workflows/a.yml", &steps);
    let r = read(dir.path());
    assert_eq!(r.setup.len(), MAX_SETUP);
    assert_eq!(r.setup.iter().filter(|s| s.ends_with("pkg0")).count(), 1);
}

#[test]
fn no_ci_files_is_empty() {
    let dir = tempfile::tempdir().unwrap();
    assert!(read(dir.path()).is_empty());
}
