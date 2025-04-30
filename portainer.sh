#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# Source: https://github.com/votre-utilisateur/votre-repo

set -euo pipefail
shopt -s inherit_errexit

# Variables configurables (modifiables par l'utilisateur)
VM_ID="9000"                  # ID de la VM
VM_NAME="Docker-Portainer"    # Nom de la VM
VM_MEMORY="2048"             # Mémoire (MB)
VM_CORES="2"                 # Nombre de cœurs
VM_DISK_SIZE="20G"           # Taille du disque
VM_USER="b4d4dm1n"             # Utilisateur cloud-init
VM_SSH_KEY=""                # Clé SSH publique (optionnelle)

# Demander le mot de passe interactivement
read -s -p "🔒 Entrez le mot de passe pour l'utilisateur $VM_USER: " VM_PASSWORD
echo ""  # Saut de ligne après le mot de passe

# Vérification des dépendances
for cmd in qm curl jq; do
  if ! command -v $cmd &> /dev/null; then
    echo "❌ Erreur: $cmd n'est pas installé. Installez-le avant de continuer."
    exit 1
  fi
done

# Fonction principale
create_vm() {
  echo "⚡ Création de la VM $VM_ID ($VM_NAME)..."
  qm create $VM_ID \
    --name "$VM_NAME" \
    --memory $VM_MEMORY \
    --cores $VM_CORES \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-pci \
    --scsi0 local-lvm:0,size=$VM_DISK_SIZE \
    --ide2 local-lvm:cloudinit \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1 \
    --onboot 1 \
    --ostype l26

  # Configuration cloud-init
  echo "⚙️ Configuration de cloud-init..."
  qm set $VM_ID \
    --ciuser "$VM_USER" \
    --cipassword "$VM_PASSWORD" \
    --sshkeys "${VM_SSH_KEY:-}" \
    --ipconfig0 ip=dhcp

  # Téléchargement de l'image Debian
  echo "📥 Téléchargement de l'image Debian 12..."
  DEBIAN_IMG="debian-12-generic-amd64.qcow2"
  if [ ! -f "/var/lib/vz/template/qemu/$DEBIAN_IMG" ]; then
    curl -fL "https://cloud.debian.org/images/cloud/bookworm/latest/$DEBIAN_IMG" \
      -o "/var/lib/vz/template/qemu/$DEBIAN_IMG" || {
      echo "❌ Échec du téléchargement de l'image Debian"
      exit 1
    }
  fi

  # Importation du disque
  qm importdisk $VM_ID "/var/lib/vz/template/qemu/$DEBIAN_IMG" local-lvm
  qm set $VM_ID --scsi0 local-lvm:${VM_ID}/vm-${VM_ID}-disk-0.raw

  # Script cloud-init pour Docker et Portainer
  echo "🐳 Installation de Docker et Portainer..."
  mkdir -p /var/lib/vz/snippets
  cat > /var/lib/vz/snippets/install-docker.yaml <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
runcmd:
  - mkdir -p /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  - echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update -y
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  - systemctl enable --now docker
  - docker volume create portainer_data
  - docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
EOF

  qm set $VM_ID --cicustom "user=local:snippets/install-docker.yaml"

  # Démarrer la VM
  echo "🚀 Démarrage de la VM..."
  qm start $VM_ID
  echo -e "\n✅ VM $VM_NAME (ID: $VM_ID) est prête !"
  echo -e "📌 Accès:"
  echo -e "   - SSH: ssh $VM_USER@<IP_VM>"
  echo -e "   - Portainer: https://<IP_VM>:9443"
  echo -e "🔑 Mot de passe: [celui que vous avez choisi]"
}

# Exécution
create_vm