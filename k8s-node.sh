set -e
swapoff -a; sed -i '/ swap / s/^/#/' /etc/fstab
printf "overlay\nbr_netfilter\n" > /etc/modules-load.d/k8s.conf
modprobe overlay; modprobe br_netfilter
printf "net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n" > /etc/sysctl.d/k8s.conf
sysctl --system >/dev/null
apt-get update -q && apt-get install -yq containerd curl gpg apt-transport-https
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/k8s.gpg
echo 'deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q && apt-get install -yq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
