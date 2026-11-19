terraform {
  required_providers {
    libvirt = { source = "dmacvicar/libvirt", version = "0.8.3" }
  }
}
provider "libvirt" { uri = "qemu:///system" }

resource "libvirt_volume" "base" {
  name   = "noble.qcow2"
  source = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

resource "libvirt_volume" "disk" {
  count          = 10
  name           = "vm-${count.index}.qcow2"
  base_volume_id = libvirt_volume.base.id
  size           = 21474836480 # 20 GB
}

resource "libvirt_cloudinit_disk" "init" {
  name      = "init.iso"
  user_data = <<-EOF
    #cloud-config
    ssh_authorized_keys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILwxBiW0xxxy0qHh8rR7zGBSddwipyw9L20EV+5SLrwi info@server-07
"]
  EOF
}

resource "libvirt_domain" "vm" {
  count     = 10
  name      = "vm-${count.index}"
  vcpu      = 8
  memory    = 16384
  cloudinit = libvirt_cloudinit_disk.init.id
  disk { volume_id = libvirt_volume.disk[count.index].id }
  network_interface {
    network_name   = "default"
    wait_for_lease = true
  }
}

output "ips" { value = libvirt_domain.vm[*].network_interface[0].addresses }
