//! The libvirt driver: `virsh` for the verbs, `qemu-img` for the overlay disk (RFD 0100
//! section 5, the libvirt/KVM column). Each slot's disk is a qcow2 overlay on the host's
//! base image, so a create copies nothing; its domain is defined from an XML template.

use super::{DOMAIN_PREFIX, HypervisorDriver, PauseMode, Slot, SlotName, SlotSpec, SlotState};
use anyhow::{Context, Result, anyhow, bail};
use std::path::PathBuf;

/// What one program run returned.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RunOutput {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
}

/// Runs `virsh` and `qemu-img`; the tests put a fake in its place.
pub trait Runner {
    fn run(&self, program: &str, args: &[String]) -> Result<RunOutput>;
}

/// The real programs, with no shell between.
pub struct ProcessRunner;

impl Runner for ProcessRunner {
    fn run(&self, program: &str, args: &[String]) -> Result<RunOutput> {
        let out = std::process::Command::new(program)
            .args(args)
            .stdin(std::process::Stdio::null())
            .output()
            .with_context(|| format!("run {program}"))?;
        Ok(RunOutput {
            ok: out.status.success(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })
    }
}

/// The default domain: KVM, virtio disk and NIC on a libvirt network, a serial console
/// and the qemu guest agent channel (`virsh qemu-agent-command`, section 5's guest exec).
pub const DEFAULT_TEMPLATE: &str = r#"<domain type='kvm'>
  <name>{{name}}</name>
  <memory unit='MiB'>{{memory_mib}}</memory>
  <vcpu>{{vcpus}}</vcpu>
  <os><type arch='x86_64'>hvm</type><boot dev='hd'/></os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='{{disk}}'/>
      <target dev='vda' bus='virtio'/>
    </disk>{{seed_disk}}
    <interface type='network'>
      <source network='{{network}}'/>
      <model type='virtio'/>
    </interface>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <serial type='pty'/>
    <console type='pty'/>
  </devices>
</domain>
"#;

pub struct LibvirtConfig {
    /// `virsh -c URI`; libvirt's default when None.
    pub connect: Option<String>,
    pub virsh: String,
    pub qemu_img: String,
    /// The qcow2 every slot's overlay is backed by. A create fails without one.
    pub base_image: Option<PathBuf>,
    /// Where overlays, seed ISOs and domain XML files live.
    pub images_dir: PathBuf,
    pub network: String,
    pub template: String,
}

impl LibvirtConfig {
    pub fn new(images_dir: PathBuf) -> Self {
        Self {
            connect: None,
            virsh: "virsh".into(),
            qemu_img: "qemu-img".into(),
            base_image: None,
            images_dir,
            network: "default".into(),
            template: DEFAULT_TEMPLATE.into(),
        }
    }
}

pub struct LibvirtDriver<R: Runner> {
    pub config: LibvirtConfig,
    pub runner: R,
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('\'', "&apos;")
        .replace('"', "&quot;")
}

/// Parse `virsh domstate --reason` ("running (booted)", "paused (user)", "shut off (saved)").
pub fn parse_domstate(text: &str) -> Option<SlotState> {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty())?;
    let (state, reason) = match line.split_once(" (") {
        Some((s, r)) => (s, r.trim_end_matches(')')),
        None => (line, ""),
    };
    Some(match state {
        "running" | "blocked" | "in shutdown" => SlotState::Running,
        "paused" | "pmsuspended" => SlotState::Paused,
        "shut off" | "crashed" if reason == "saved" => SlotState::Saved,
        "shut off" | "crashed" => SlotState::Stopped,
        _ => return None,
    })
}

fn is_missing(out: &RunOutput) -> bool {
    let e = out.stderr.to_ascii_lowercase();
    e.contains("failed to get domain") || e.contains("domain not found")
}

impl<R: Runner> LibvirtDriver<R> {
    pub fn new(config: LibvirtConfig, runner: R) -> Self {
        Self { config, runner }
    }

    fn virsh(&self, args: &[&str]) -> Result<RunOutput> {
        let mut full: Vec<String> = Vec::new();
        if let Some(uri) = &self.config.connect {
            full.extend(["-c".to_owned(), uri.clone()]);
        }
        full.extend(args.iter().map(|a| (*a).to_owned()));
        self.runner.run(&self.config.virsh, &full)
    }

    fn virsh_ok(&self, args: &[&str]) -> Result<RunOutput> {
        let out = self.virsh(args)?;
        if !out.ok {
            bail!("virsh {}: {}", args.join(" "), out.stderr.trim());
        }
        Ok(out)
    }

    /// The slot's state, or None when no such domain exists.
    pub fn state(&self, slot: &SlotName) -> Result<Option<SlotState>> {
        let domain = slot.domain();
        let out = self.virsh(&["domstate", &domain, "--reason"])?;
        if !out.ok {
            if is_missing(&out) {
                return Ok(None);
            }
            bail!("virsh domstate {domain}: {}", out.stderr.trim());
        }
        parse_domstate(&out.stdout).map(Some).ok_or_else(|| {
            anyhow!("virsh domstate {domain}: unknown state {:?}", out.stdout.trim())
        })
    }

    pub fn overlay_path(&self, slot: &SlotName) -> PathBuf {
        self.config.images_dir.join(format!("{}.qcow2", slot.domain()))
    }

    pub fn seed_path(&self, slot: &SlotName) -> PathBuf {
        self.config.images_dir.join(format!("{}-seed.iso", slot.domain()))
    }

    fn xml_path(&self, slot: &SlotName) -> PathBuf {
        self.config.images_dir.join(format!("{}.xml", slot.domain()))
    }

    /// The domain XML for a slot, from the template.
    pub fn domain_xml(&self, slot: &SlotName, spec: &SlotSpec) -> String {
        let seed = self.seed_path(slot);
        let seed_disk = if seed.exists() {
            format!(
                "\n    <disk type='file' device='cdrom'>\n      <driver name='qemu' type='raw'/>\n      <source file='{}'/>\n      <target dev='sda' bus='sata'/>\n      <readonly/>\n    </disk>",
                xml_escape(&seed.display().to_string())
            )
        } else {
            String::new()
        };
        self.config
            .template
            .replace("{{name}}", &xml_escape(&slot.domain()))
            .replace("{{memory_mib}}", &spec.memory_mib.to_string())
            .replace("{{vcpus}}", &spec.vcpus.to_string())
            .replace("{{disk}}", &xml_escape(&self.overlay_path(slot).display().to_string()))
            .replace("{{network}}", &xml_escape(&self.config.network))
            .replace("{{seed_disk}}", &seed_disk)
    }
}

impl<R: Runner> HypervisorDriver for LibvirtDriver<R> {
    // `spec.join` (a hub-minted child join token) is not handed to a KVM guest yet: it has no
    // channel into the guest's environment here, so it goes unused and expires on the hub.
    fn create(&self, slot: &SlotName, spec: &SlotSpec) -> Result<SlotState> {
        if let Some(state) = self.state(slot)? {
            return Ok(state);
        }
        let base = self
            .config
            .base_image
            .as_ref()
            .ok_or_else(|| anyhow!("create {slot}: no base image (--base-image)"))?;
        std::fs::create_dir_all(&self.config.images_dir)
            .with_context(|| format!("create {}", self.config.images_dir.display()))?;
        let overlay = self.overlay_path(slot);
        if !overlay.exists() {
            let mut args: Vec<String> = ["create", "-f", "qcow2", "-F", "qcow2", "-b"]
                .iter()
                .map(|s| (*s).to_owned())
                .collect();
            args.push(base.display().to_string());
            args.push(overlay.display().to_string());
            if spec.disk_gib > 0 {
                args.push(format!("{}G", spec.disk_gib));
            }
            let out = self.runner.run(&self.config.qemu_img, &args)?;
            if !out.ok {
                bail!("qemu-img create {}: {}", overlay.display(), out.stderr.trim());
            }
        }
        let xml_path = self.xml_path(slot);
        std::fs::write(&xml_path, self.domain_xml(slot, spec))
            .with_context(|| format!("write {}", xml_path.display()))?;
        self.virsh_ok(&["define", &xml_path.display().to_string()])?;
        self.virsh_ok(&["start", &slot.domain()])?;
        Ok(SlotState::Running)
    }

    fn pause(&self, slot: &SlotName, mode: PauseMode) -> Result<SlotState> {
        let domain = slot.domain();
        let state = self.state(slot)?.ok_or_else(|| anyhow!("pause {slot}: no such slot"))?;
        match (state, mode) {
            (SlotState::Running, PauseMode::Memory) => {
                self.virsh_ok(&["suspend", &domain])?;
                Ok(SlotState::Paused)
            }
            (SlotState::Running | SlotState::Paused, PauseMode::Disk) => {
                self.virsh_ok(&["managedsave", &domain])?;
                Ok(SlotState::Saved)
            }
            // Already paused at least this far, or not running at all.
            (s, _) => Ok(s),
        }
    }

    fn resume(&self, slot: &SlotName) -> Result<SlotState> {
        let domain = slot.domain();
        match self.state(slot)?.ok_or_else(|| anyhow!("resume {slot}: no such slot"))? {
            SlotState::Running => {}
            SlotState::Paused => {
                self.virsh_ok(&["resume", &domain])?;
            }
            // `start` restores a managed save, else boots.
            SlotState::Saved | SlotState::Stopped => {
                self.virsh_ok(&["start", &domain])?;
            }
        }
        Ok(SlotState::Running)
    }

    fn destroy(&self, slot: &SlotName) -> Result<()> {
        let domain = slot.domain();
        match self.state(slot)? {
            None => {}
            Some(state) => {
                if matches!(state, SlotState::Running | SlotState::Paused) {
                    let out = self.virsh(&["destroy", &domain])?;
                    if !out.ok && !is_missing(&out) {
                        bail!("virsh destroy {domain}: {}", out.stderr.trim());
                    }
                }
                let out = self.virsh(&[
                    "undefine",
                    &domain,
                    "--managed-save",
                    "--snapshots-metadata",
                    "--remove-all-storage",
                ])?;
                if !out.ok && !is_missing(&out) {
                    bail!("virsh undefine {domain}: {}", out.stderr.trim());
                }
            }
        }
        // libvirt removes only pool volumes; the overlay is a plain file.
        for path in [self.overlay_path(slot), self.seed_path(slot), self.xml_path(slot)] {
            match std::fs::remove_file(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e).with_context(|| format!("remove {}", path.display())),
            }
        }
        Ok(())
    }

    fn list(&self) -> Result<Vec<Slot>> {
        let out = self.virsh_ok(&["list", "--all", "--name"])?;
        let mut slots = Vec::new();
        for domain in out.stdout.lines().map(str::trim).filter(|d| d.starts_with(DOMAIN_PREFIX)) {
            let Some(name) = SlotName::from_domain(domain) else { continue };
            // A domain undefined between the two calls is simply gone.
            if let Some(state) = self.state(&name)? {
                slots.push(Slot { name, state });
            }
        }
        slots.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(slots)
    }
}
