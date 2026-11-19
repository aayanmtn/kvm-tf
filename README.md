# KVM VMs with Terraform (libvirt) + kubeadm cluster

Spin up Ubuntu 24.04 VMs on a single KVM host using Terraform and the
[`dmacvicar/libvirt`](https://registry.terraform.io/providers/dmacvicar/libvirt/latest) provider,
then build a Kubernetes cluster (1 master, 3 workers) on them with kubeadm.

## Host

| Item    | Value                                             |
|---------|---------------------------------------------------|
| Host    | `server-07` (reached over Tailscale, no public IP) |
| OS      | Ubuntu 24.04 LTS                                  |
| CPU     | Intel Xeon 6766E, 288 cores                       |
| RAM     | ~503 GB                                           |
| VM net  | libvirt `default` NAT, `192.168.122.0/24`         |

## What `main.tf` creates

| Resource                       | Count | Purpose                                                      |
|--------------------------------|-------|--------------------------------------------------------------|
| `libvirt_volume.base`          | 1     | Ubuntu 24.04 cloud image (`noble.qcow2`), read-only template |
| `libvirt_volume.disk`          | 10    | 20 GB copy-on-write disks on top of the base image           |
| `libvirt_cloudinit_disk.init`  | 1     | cloud-init ISO that installs the SSH key on first boot       |
| `libvirt_domain.vm`            | 10    | VMs `vm-0` … `vm-9`, 8 vCPU / 16 GB RAM each                 |
| `output.ips`                   | –     | IP address of every VM                                       |

Provider is pinned to **0.8.3**: version 0.9+ uses a different, incompatible schema.

## 1. One-time host setup

```bash
# KVM, libvirt, ISO tool for cloud-init, Terraform
sudo apt install -y qemu-kvm libvirt-daemon-system genisoimage
command -v mkisofs || sudo ln -s /usr/bin/genisoimage /usr/local/bin/mkisofs
sudo snap install terraform --classic
sudo usermod -aG libvirt $USER        # log out and back in after this

# Storage pool "default"
sudo virsh pool-define-as default dir --target /var/lib/libvirt/images
sudo virsh pool-build default
sudo virsh pool-start default
sudo virsh pool-autostart default

# Network "default" (usually already active)
sudo virsh net-start default 2>/dev/null; sudo virsh net-autostart default

# Ubuntu AppArmor blocks QEMU from reading the disks. Disable the security driver (test box only)
grep -q '^security_driver' /etc/libvirt/qemu.conf || \
  echo 'security_driver = "none"' | sudo tee -a /etc/libvirt/qemu.conf
sudo systemctl restart libvirtd
```

## 2. SSH key

The VMs accept logins only with the key placed in the cloud-config inside `main.tf`.

```bash
cat ~/.ssh/id_ed25519.pub      # or create one: ssh-keygen -t ed25519
```

Paste it into `main.tf`, keeping this exact indentation:

```yaml
    #cloud-config
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... user@server-07
```

## 3. Create the VMs

```bash
terraform init
terraform apply -auto-approve
terraform output ips
```

Log in as **`ubuntu`** (root SSH login is disabled in cloud images):

```bash
ssh ubuntu@192.168.122.x
```

Always run Terraform as the **same user** from this folder. The state file
(`terraform.tfstate`) is what Terraform uses to track and delete resources.

## 4. Kubernetes (kubeadm v1.36): 1 master + 3 workers

Run from the host. Set the IPs from `terraform output ips`:

```bash
M=192.168.122.25                                    # master (vm-0)
W="192.168.122.239 192.168.122.91 192.168.122.53"   # workers (vm-1..3)
```

**Unique hostnames** (required, since all VMs boot as `ubuntu`):

```bash
ssh ubuntu@$M sudo hostnamectl set-hostname k8s-master
n=1; for ip in $W; do ssh ubuntu@$ip sudo hostnamectl set-hostname k8s-worker$n; n=$((n+1)); done
```

**Prepare all nodes** with `k8s-node.sh` (swap off, kernel modules, sysctl, containerd with
systemd cgroups, kubelet/kubeadm/kubectl from `pkgs.k8s.io` v1.36):

```bash
for ip in $M $W; do ssh ubuntu@$ip 'sudo bash -s' < k8s-node.sh > log-$ip.txt 2>&1 & done; wait
tail -n 2 log-*.txt
```

**Init the master + Flannel CNI**:

```bash
ssh ubuntu@$M "sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$M"
ssh ubuntu@$M 'mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config'
ssh ubuntu@$M kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Pod CIDR is `10.244.0.0/16` on purpose: Calico's default `192.168.0.0/16` overlaps the VM network.

**Join the workers**:

```bash
JOIN=$(ssh ubuntu@$M sudo kubeadm token create --print-join-command)
for ip in $W; do ssh ubuntu@$ip "sudo $JOIN"; done
ssh ubuntu@$M kubectl get nodes -o wide
```

## Networking

| From → To              | Works? | Notes                                                 |
|------------------------|--------|-------------------------------------------------------|
| VM ↔ VM                | Yes    | Same NAT bridge (`virbr0`), all ports open            |
| VM → Internet          | Yes    | NAT through the host                                  |
| Host → VM              | Yes    | SSH from `server-07`                                  |
| Laptop/phone → VM      | Optional | `sudo tailscale up --advertise-routes=192.168.122.0/24`, then approve the route in the Tailscale admin panel |

## Common changes

- **More or fewer VMs**: change `count` on both `libvirt_volume.disk` and `libvirt_domain.vm`.
- **Bigger VMs**: change `vcpu` / `memory` (MB) / disk `size` (bytes).
- Then `terraform apply`. Only the differences are applied.
- cloud-init runs **only on first boot**. After changing `user_data`, rebuild:
  `terraform destroy -auto-approve && terraform apply -auto-approve`.

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `can't find storage pool 'default'` | No libvirt pool | Create the pool (step 1) |
| `exec: "mkisofs": executable file not found` | ISO tool missing | `apt install genisoimage` + symlink (step 1) |
| `Could not open '.../noble.qcow2': Permission denied` | AppArmor | `security_driver = "none"` + restart libvirtd. Write it with `sudo tee`, since `sudo echo >>` doesn't work |
| `domain 'vm-N' already exists` | VMs left behind by a failed apply (not in state) | `for i in $(seq 0 9); do virsh destroy vm-$i; virsh undefine vm-$i --nvram \|\| virsh undefine vm-$i; done` |
| `Permission denied (publickey)` | Wrong user, wrong key, or broken cloud-config YAML | Log in as `ubuntu` with the key in `main.tf`, check the YAML, then rebuild |

`terraform destroy` only removes resources recorded in the state. Leftover VMs need `virsh undefine`.

## Cleanup

```bash
terraform destroy -auto-approve
virsh list --all          # should be empty
```
