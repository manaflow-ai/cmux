# Boots a Tart VM into macOS Recovery and turns SIP off, so the golden image can
# pre-grant Accessibility, Screen Recording and Apple Events in TCC.db for the
# benchmark (a disposable VM; never do this on a real Mac). The key sequence is
# the one Cirrus Labs' macos-image-templates uses.
packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type = string
}

source "tart-cli" "tart" {
  vm_name      = "${var.vm_name}"
  recovery     = true
  cpu_count    = 4
  memory_gb    = 8
  communicator = "none"
  boot_command = [
    "<wait60s><right><right><enter>",
    "<wait10s><leftAltOn>T<leftAltOff>",
    "<wait10s>csrutil disable<enter>",
    "<wait10s>y<enter>",
    "<wait10s>admin<enter>",
    "<wait10s>halt<enter>"
  ]
}

build {
  sources = ["source.tart-cli.tart"]
}
