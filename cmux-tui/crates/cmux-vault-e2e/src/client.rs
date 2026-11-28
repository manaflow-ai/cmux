//! Every person operation of the vault, over an [`Http`] (the caller's transport, with the person's bearer) and a
//! [`DeviceStore`] (this device's id and private key, in the OS secret store). No I/O of its own.
//!
//! Routes: cmux-platform `SealedVaultRoute.ts`, under `/v1/cloud/vault` on the Cloud API origin.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::crypto::{self, DeviceKey, ItemPlace, Sealed, SealedItem, VaultKey};
use crate::plan::{self, ItemMeta, MachineMeta};
use crate::{Scope, b64};

pub const BASE: &str = "/v1/cloud/vault";
pub const DEVICE_HEADER: &str = "x-cmux-vault-device";

/// The transport. `path` starts with `/v1/`; `body` is JSON. Answers the status and the JSON body (or `Null`).
/// An `Err` is a transport failure (no answer), its text free of any value.
pub trait Http {
    fn send(
        &self,
        method: &str,
        path: &str,
        headers: &[(&str, &str)],
        body: Option<&Value>,
    ) -> Result<(u16, Value), String>;
}

/// This device's identity, in the OS secret store.
pub trait DeviceStore {
    /// `(device id, private key)`, if this device has one.
    fn load(&self) -> Result<Option<DeviceRecord>, String>;
    fn save(&self, id: &str, private_key: &[u8]) -> Result<(), String>;
}

/// A refusal or failure: a stable code and a message free of values.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub code: String,
    pub message: String,
}

impl Failure {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into() }
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl From<crypto::CryptoError> for Failure {
    fn from(error: crypto::CryptoError) -> Self {
        Failure::new(error.code(), "a vault key or item did not open or seal")
    }
}

pub type VaultResult<T> = Result<T, Failure>;

/// A device's id and its private key.
pub type DeviceRecord = (String, Zeroizing<Vec<u8>>);

/// `personal` or `team:<team id>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaultRef(pub String);

impl VaultRef {
    pub fn personal() -> Self {
        Self("personal".to_owned())
    }

    pub fn parse(text: &str) -> Option<Self> {
        if text == "personal" {
            return Some(Self::personal());
        }
        let team = text.strip_prefix("team:")?;
        (team.starts_with("team_")
            && team.len() <= 69
            && team.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b)))
        .then(|| Self(text.to_owned()))
    }

    fn query(&self) -> String {
        format!("vault={}", self.0.replace(':', "%3A"))
    }
}

/// A device as the vault lists it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Device {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub state: String,
    #[serde(rename = "safetyCode")]
    pub safety_code: String,
    #[serde(rename = "thisDevice")]
    pub this_device: bool,
    #[serde(skip)]
    public_key: Vec<u8>,
}

/// An item as surfaces show it: never its value.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ItemView {
    pub id: String,
    pub name: String,
    pub scope: String,
    #[serde(rename = "scopeLabel")]
    pub scope_label: String,
    pub revision: u64,
    #[serde(rename = "updatedAt")]
    pub updated_at: u64,
    pub masked: &'static str,
}

/// What `status` answers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    pub vault: String,
    /// `off` (no device yet), `pending` (this device waits for an approve), `active`, or `not_enrolled` (the vault
    /// has devices, this one is not among them).
    pub state: String,
    pub epoch: u64,
    #[serde(rename = "deviceId")]
    pub device_id: Option<String>,
    #[serde(rename = "safetyCode")]
    pub safety_code: Option<String>,
    pub devices: Vec<Device>,
    pub items: Vec<ItemView>,
}

struct RawItem {
    id: String,
    name: String,
    scope: String,
    revision: u64,
    epoch: u64,
    sealed: SealedItem,
    updated_at: u64,
}

struct Snapshot {
    epoch: u64,
    devices: Vec<Device>,
    items: Vec<RawItem>,
    wrap: Option<(u64, Sealed)>,
}

/// One machine and what sync did for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MachineSync {
    pub id: String,
    pub name: Option<String>,
    pub spare: bool,
    /// `delivered`, `current`, `no_key` (not bound yet), `failed`.
    pub outcome: String,
    pub names: Vec<String>,
}

/// The vault for one person on one device.
pub struct Vault<'a, H: Http, S: DeviceStore> {
    pub http: &'a H,
    pub store: &'a S,
    pub vault: VaultRef,
    /// The machine kind label this device registers as (`mac`, `iphone`, `cli`, `linux`).
    pub kind: String,
    /// The label shown to the person's other devices (`Leo's MacBook Pro`).
    pub label: String,
    /// The clock, in Unix ms (revisions are times: strictly increasing per name on every device).
    pub now_ms: fn() -> u64,
}

pub fn system_now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

fn refusal(status: u16, body: &Value) -> Failure {
    let error = body.get("error");
    let code = error.and_then(|e| e.get("code")).and_then(Value::as_str).unwrap_or("vault.http");
    let message = error
        .and_then(|e| e.get("message"))
        .and_then(Value::as_str)
        .map_or_else(|| format!("the vault answered {status}"), str::to_owned);
    Failure::new(code, message)
}

fn field<'v>(value: &'v Value, key: &str) -> Option<&'v Value> {
    value.get(key)
}

impl<'a, H: Http, S: DeviceStore> Vault<'a, H, S> {
    fn call(
        &self,
        method: &str,
        path: &str,
        device: Option<&str>,
        body: Option<&Value>,
    ) -> VaultResult<Value> {
        let headers: Vec<(&str, &str)> =
            device.map(|d| vec![(DEVICE_HEADER, d)]).unwrap_or_default();
        let (status, answer) = self
            .http
            .send(method, path, &headers, body)
            .map_err(|message| Failure::new("vault.transport", message))?;
        if (200..300).contains(&status) { Ok(answer) } else { Err(refusal(status, &answer)) }
    }

    /// This device's key, made and saved the first time.
    fn device(&self) -> VaultResult<(String, DeviceKey)> {
        if let Some((id, private)) =
            self.store.load().map_err(|m| Failure::new("vault.device_store", m))?
        {
            return Ok((id, DeviceKey::from_private(&private)?));
        }
        let key = DeviceKey::generate()?;
        let mut raw = [0_u8; 9];
        getrandom::fill(&mut raw)
            .map_err(|_| Failure::new("vault.random", "no system randomness"))?;
        let id = format!("dev_{}", b64::encode(&raw));
        self.store
            .save(&id, key.private_bytes())
            .map_err(|m| Failure::new("vault.device_store", m))?;
        Ok((id, key))
    }

    fn device_if_any(&self) -> VaultResult<Option<(String, DeviceKey)>> {
        match self.store.load().map_err(|m| Failure::new("vault.device_store", m))? {
            Some((id, private)) => Ok(Some((id, DeviceKey::from_private(&private)?))),
            None => Ok(None),
        }
    }

    fn snapshot(&self, device: Option<&str>) -> VaultResult<Snapshot> {
        let answer = self.call("GET", &format!("{BASE}?{}", self.vault.query()), device, None)?;
        let bad = || Failure::new("vault.bad_answer", "the vault's answer was not readable");
        let epoch = field(&answer, "epoch").and_then(Value::as_u64).unwrap_or(0);
        let mut devices = Vec::new();
        for raw in field(&answer, "devices").and_then(Value::as_array).cloned().unwrap_or_default()
        {
            let public_key = raw
                .get("publicKey")
                .and_then(Value::as_str)
                .and_then(b64::decode)
                .ok_or_else(bad)?;
            let id = raw.get("id").and_then(Value::as_str).ok_or_else(bad)?.to_owned();
            devices.push(Device {
                this_device: Some(id.as_str()) == device,
                id,
                kind: raw.get("kind").and_then(Value::as_str).unwrap_or_default().to_owned(),
                label: raw.get("label").and_then(Value::as_str).unwrap_or_default().to_owned(),
                state: raw.get("state").and_then(Value::as_str).unwrap_or_default().to_owned(),
                safety_code: crypto::safety_code(&public_key),
                public_key,
            });
        }
        let mut items = Vec::new();
        for raw in field(&answer, "items").and_then(Value::as_array).cloned().unwrap_or_default() {
            let text =
                |k: &str| raw.get(k).and_then(Value::as_str).map(str::to_owned).ok_or_else(bad);
            let nonce: [u8; 24] =
                b64::decode(&text("nonce")?).and_then(|n| n.try_into().ok()).ok_or_else(bad)?;
            items.push(RawItem {
                id: text("id")?,
                name: text("name")?,
                scope: text("scope")?,
                revision: raw.get("revision").and_then(Value::as_u64).ok_or_else(bad)?,
                epoch: raw.get("epoch").and_then(Value::as_u64).ok_or_else(bad)?,
                sealed: SealedItem {
                    nonce,
                    ciphertext: b64::decode(&text("ciphertext")?).ok_or_else(bad)?,
                },
                updated_at: raw.get("updatedAt").and_then(Value::as_u64).unwrap_or(0),
            });
        }
        let wrap = field(&answer, "wrap").and_then(|w| {
            Some((
                w.get("epoch")?.as_u64()?,
                Sealed {
                    enc: b64::decode(w.get("enc")?.as_str()?)?,
                    ct: b64::decode(w.get("ct")?.as_str()?)?,
                },
            ))
        });
        Ok(Snapshot { epoch, devices, items, wrap })
    }

    fn key_of(&self, snap: &Snapshot, id: &str, device: &DeviceKey) -> VaultResult<VaultKey> {
        let Some((epoch, wrap)) = &snap.wrap else {
            return Err(Failure::new(
                "vault.not_approved",
                "this device is not approved yet: approve it from one of your other devices (cmux vault approve CODE)",
            ));
        };
        if *epoch != snap.epoch {
            return Err(Failure::new(
                "vault.stale_wrap",
                "this device's key is from an older epoch: approve it again",
            ));
        }
        Ok(crypto::unwrap_key(device, &self.vault.0, id, *epoch, wrap)?)
    }

    fn views(snap: &Snapshot) -> Vec<ItemView> {
        let mut views: Vec<ItemView> = snap
            .items
            .iter()
            .map(|i| ItemView {
                id: i.id.clone(),
                name: i.name.clone(),
                scope: i.scope.clone(),
                scope_label: Scope::parse(&i.scope).map_or_else(|| i.scope.clone(), |s| s.label()),
                revision: i.revision,
                updated_at: i.updated_at,
                masked: crate::mask(""),
            })
            .collect();
        views.sort_by(|a, b| {
            (a.name.as_str(), a.scope.as_str()).cmp(&(b.name.as_str(), b.scope.as_str()))
        });
        views
    }

    /// The vault as this device sees it. Never makes a device key.
    pub fn status(&self) -> VaultResult<Status> {
        let device = self.device_if_any()?;
        let id = device.as_ref().map(|(id, _)| id.clone());
        let snap = self.snapshot(id.as_deref())?;
        let me = id.as_ref().and_then(|id| snap.devices.iter().find(|d| &d.id == id));
        let state = match me {
            Some(d) if d.state == "active" => "active",
            Some(_) => "pending",
            None if snap.devices.is_empty() => "off",
            None => "not_enrolled",
        };
        Ok(Status {
            vault: self.vault.0.clone(),
            state: state.to_owned(),
            epoch: snap.epoch,
            safety_code: device.as_ref().map(|(_, k)| crypto::safety_code(k.public_bytes())),
            device_id: id,
            items: Self::views(&snap),
            devices: snap.devices,
        })
    }

    /// Turn the vault on for this device: the first device makes the vault key; a later one asks to join (an
    /// active device approves it by its safety code).
    pub fn enroll(&self) -> VaultResult<Status> {
        let (id, key) = self.device()?;
        let snap = self.snapshot(Some(&id))?;
        if snap.devices.iter().any(|d| d.id == id) {
            return self.status();
        }
        let mut body = json!({
            "vault": self.vault.0,
            "id": id,
            "kind": self.kind,
            "label": self.label,
            "publicKey": b64::encode(key.public_bytes()),
        });
        // The server's bootstrap (cmux-platform SealedVault.ts addDevice): a vault with no active device and no
        // item takes its first device's own wrap at the NEXT epoch. A vault whose devices were all removed keeps
        // its epoch, so that is not always 1 (vault-e2e.ts run 45703929549: "the first device's wrap is for epoch 2").
        if !snap.devices.iter().any(|d| d.state == "active") && snap.items.is_empty() {
            let epoch = snap.epoch + 1;
            let vk = VaultKey::generate()?;
            let wrap = crypto::wrap_key(&vk, &self.vault.0, &id, key.public_bytes(), epoch)?;
            if let Some(fields) = body.as_object_mut() {
                fields.insert(
                    "wrap".to_owned(),
                    json!({"epoch": epoch, "enc": b64::encode(&wrap.enc), "ct": b64::encode(&wrap.ct)}),
                );
            }
        }
        self.call("POST", &format!("{BASE}/devices"), Some(&id), Some(&body))?;
        self.status()
    }

    /// Approve the pending device whose safety code is `code`.
    pub fn approve(&self, code: &str) -> VaultResult<Device> {
        let (id, key) = self.device()?;
        let snap = self.snapshot(Some(&id))?;
        let vk = self.key_of(&snap, &id, &key)?;
        let matches: Vec<&Device> = snap
            .devices
            .iter()
            .filter(|d| d.state == "pending" && crypto::same_code(&d.safety_code, code))
            .collect();
        let [target] = matches.as_slice() else {
            return Err(Failure::new(
                "vault.no_such_code",
                "no waiting device shows that code: check the 8 digits on the new device",
            ));
        };
        let wrap =
            crypto::wrap_key(&vk, &self.vault.0, &target.id, &target.public_key, snap.epoch)?;
        let body = json!({"vault": self.vault.0, "epoch": snap.epoch, "enc": b64::encode(&wrap.enc), "ct": b64::encode(&wrap.ct)});
        self.call(
            "POST",
            &format!("{BASE}/devices/{}/approve", target.id),
            Some(&id),
            Some(&body),
        )?;
        Ok((*target).clone())
    }

    /// Remove a device, then rotate the vault key so it opens nothing new.
    pub fn remove_device(&self, device_id: &str) -> VaultResult<u64> {
        let (id, _) = self.device()?;
        self.call(
            "DELETE",
            &format!("{BASE}/devices/{device_id}?{}", self.vault.query()),
            Some(&id),
            None,
        )?;
        if device_id == id { Ok(0) } else { self.rotate() }
    }

    /// A new vault key (epoch + 1): every item re-sealed, wrapped to every active device but removed ones.
    pub fn rotate(&self) -> VaultResult<u64> {
        let (id, key) = self.device()?;
        let snap = self.snapshot(Some(&id))?;
        let old = self.key_of(&snap, &id, &key)?;
        let next = VaultKey::generate()?;
        let epoch = snap.epoch + 1;
        let mut items = Vec::new();
        for item in &snap.items {
            let value = crypto::open_item(
                &old,
                &place(&self.vault.0, item, item.revision, item.epoch),
                &item.sealed,
            )?;
            let sealed = crypto::seal_item(
                &next,
                &place(&self.vault.0, item, item.revision, epoch),
                &value,
            )?;
            items.push(json!({
                "id": item.id, "name": item.name, "scope": item.scope, "revision": item.revision, "epoch": epoch,
                "nonce": b64::encode(&sealed.nonce), "ciphertext": b64::encode(&sealed.ciphertext),
            }));
        }
        let mut wraps = Vec::new();
        for device in snap.devices.iter().filter(|d| d.state == "active") {
            let wrap =
                crypto::wrap_key(&next, &self.vault.0, &device.id, &device.public_key, epoch)?;
            wraps.push(json!({"device": device.id, "epoch": epoch, "enc": b64::encode(&wrap.enc), "ct": b64::encode(&wrap.ct)}));
        }
        let body = json!({"vault": self.vault.0, "fromEpoch": snap.epoch, "epoch": epoch, "items": items, "wraps": wraps});
        self.call("POST", &format!("{BASE}/rotate"), Some(&id), Some(&body))?;
        Ok(epoch)
    }

    /// Keep `value` for `name` in `scope`. Returns the item's revision.
    pub fn set(&self, name: &str, scope: &Scope, value: &str) -> VaultResult<u64> {
        self.set_many(&[(name, scope, value)]).map(|r| r.first().map_or(0, |(_, rev)| *rev))
    }

    /// Several at once (an import): one snapshot, one PUT each.
    pub fn set_many(&self, entries: &[(&str, &Scope, &str)]) -> VaultResult<Vec<(String, u64)>> {
        for (name, _, value) in entries {
            if !crate::valid_name(name) {
                return Err(Failure::new(
                    "vault.bad_name",
                    format!("{name} is not a name the vault keeps"),
                ));
            }
            if value.is_empty() || value.len() > 48 * 1024 || value.contains('\0') {
                return Err(Failure::new(
                    "vault.bad_value",
                    format!("the value of {name} is empty, has a NUL or is over 48 KiB"),
                ));
            }
        }
        let (id, key) = self.device()?;
        let snap = self.snapshot(Some(&id))?;
        let vk = self.key_of(&snap, &id, &key)?;
        let mut done = Vec::new();
        for (name, scope, value) in entries {
            let scope_wire = scope.wire();
            let item_id = crypto::item_id(&self.vault.0, name, &scope_wire);
            let existing = snap.items.iter().find(|i| i.id == item_id);
            let highest = snap
                .items
                .iter()
                .filter(|i| i.name == *name)
                .map(|i| i.revision)
                .max()
                .unwrap_or(0);
            let revision = (self.now_ms)().max(highest + 1);
            let at = ItemPlace {
                vault: &self.vault.0,
                item_id: &item_id,
                name,
                scope: &scope_wire,
                revision,
                epoch: snap.epoch,
            };
            let sealed = crypto::seal_item(&vk, &at, value.as_bytes())?;
            let body = json!({
                "vault": self.vault.0, "name": name, "scope": scope_wire, "revision": revision,
                "expectedRevision": existing.map_or(0, |i| i.revision), "epoch": snap.epoch,
                "nonce": b64::encode(&sealed.nonce), "ciphertext": b64::encode(&sealed.ciphertext),
            });
            self.call("PUT", &format!("{BASE}/items/{item_id}"), Some(&id), Some(&body))?;
            done.push(((*name).to_owned(), revision));
        }
        Ok(done)
    }

    /// Remove `name` from `scope` (every scope when `None`). Returns how many items went.
    pub fn remove(&self, name: &str, scope: Option<&Scope>) -> VaultResult<usize> {
        let (id, _) = self.device()?;
        let snap = self.snapshot(Some(&id))?;
        let wanted = scope.map(Scope::wire);
        let mut count = 0;
        for item in snap
            .items
            .iter()
            .filter(|i| i.name == name && wanted.as_ref().is_none_or(|w| w == &i.scope))
        {
            let path = format!(
                "{BASE}/items/{}?{}&expectedRevision={}",
                item.id,
                self.vault.query(),
                item.revision
            );
            self.call("DELETE", &path, Some(&id), None)?;
            count += 1;
        }
        if count == 0 {
            return Err(Failure::new("vault.no_entry", format!("the vault keeps no {name} there")));
        }
        Ok(count)
    }

    /// Seal what each of the person's machines should hold, for every machine whose delivery is not current
    /// (spares included). Returns one row per machine.
    pub fn sync(&self) -> VaultResult<Vec<MachineSync>> {
        let (id, key) = self.device()?;
        let snap = self.snapshot(Some(&id))?;
        let vk = self.key_of(&snap, &id, &key)?;
        let answer =
            self.call("GET", &format!("{BASE}/machines?{}", self.vault.query()), Some(&id), None)?;
        let metas: Vec<ItemMeta> = snap
            .items
            .iter()
            .filter_map(|i| {
                Some(ItemMeta {
                    id: i.id.clone(),
                    name: i.name.clone(),
                    scope: Scope::parse(&i.scope)?,
                    revision: i.revision,
                })
            })
            .collect();
        let mut rows = Vec::new();
        for machine in answer.get("machines").and_then(Value::as_array).cloned().unwrap_or_default()
        {
            let Some(vm) = machine.get("id").and_then(Value::as_str).filter(|v| crate::is_vm(v))
            else {
                continue;
            };
            let name = machine.get("name").and_then(Value::as_str).map(str::to_owned);
            let spare = machine.get("spare").and_then(Value::as_bool).unwrap_or(false);
            let repo = machine.get("repo").and_then(Value::as_str).map(str::to_ascii_lowercase);
            let meta = MachineMeta { id: vm.to_owned(), repo };
            let chosen = plan::for_machine(&metas, &meta);
            let delivered: BTreeMap<String, u64> = machine
                .get("delivered")
                .and_then(Value::as_array)
                .map(|list| {
                    list.iter()
                        .filter_map(|d| {
                            Some((
                                d.get("name")?.as_str()?.to_owned(),
                                d.get("revision")?.as_u64()?,
                            ))
                        })
                        .collect()
                })
                .unwrap_or_default();
            let names: Vec<String> = chosen.keys().map(|n| (*n).to_owned()).collect();
            let mut row =
                MachineSync { id: vm.to_owned(), name, spare, outcome: String::new(), names };
            if plan::current(&chosen, &delivered) {
                row.outcome = "current".to_owned();
                rows.push(row);
                continue;
            }
            let Some(daemon_key) =
                machine.get("daemonKey").and_then(Value::as_str).and_then(b64::decode)
            else {
                row.outcome = "no_key".to_owned();
                rows.push(row);
                continue;
            };
            let mut items = Vec::new();
            let mut failed = false;
            for meta in chosen.values() {
                let Some(raw) = snap.items.iter().find(|i| i.id == meta.id) else { continue };
                let value = crypto::open_item(
                    &vk,
                    &place(&self.vault.0, raw, raw.revision, raw.epoch),
                    &raw.sealed,
                )?;
                match crypto::seal_delivery(&daemon_key, vm, &raw.name, raw.revision, &value) {
                    Ok(sealed) => items.push(json!({
                        "name": raw.name, "revision": raw.revision,
                        "enc": b64::encode(&sealed.enc), "ct": b64::encode(&sealed.ct),
                    })),
                    Err(_) => failed = true,
                }
            }
            if failed {
                row.outcome = "failed".to_owned();
                rows.push(row);
                continue;
            }
            let body = json!({"vault": self.vault.0, "items": items});
            row.outcome = match self.call(
                "PUT",
                &format!("{BASE}/machines/{vm}/delivery"),
                Some(&id),
                Some(&body),
            ) {
                Ok(_) => "delivered".to_owned(),
                Err(_) => "failed".to_owned(),
            };
            rows.push(row);
        }
        Ok(rows)
    }
}

fn place<'a>(vault: &'a str, item: &'a RawItem, revision: u64, epoch: u64) -> ItemPlace<'a> {
    ItemPlace { vault, item_id: &item.id, name: &item.name, scope: &item.scope, revision, epoch }
}

/// An import preview: names in file order, whether each is a name the vault keeps, and whether the vault already
/// has it in `scope`. Never a value.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewRow {
    pub name: String,
    pub line: usize,
    pub keepable: bool,
    #[serde(rename = "alreadyKept")]
    pub already_kept: bool,
    pub masked: &'static str,
}

pub fn preview(
    parsed: &crate::dotenv::Parsed,
    kept: &[ItemView],
    scope: &Scope,
) -> Vec<PreviewRow> {
    let wire = scope.wire();
    parsed
        .entries
        .iter()
        .map(|e| PreviewRow {
            name: e.name.clone(),
            line: e.line,
            keepable: crate::valid_name(&e.name),
            already_kept: kept.iter().any(|k| k.name == e.name && k.scope == wire),
            masked: crate::mask(&e.value),
        })
        .collect()
}
