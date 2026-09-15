#!/usr/bin/env bash
set -euo pipefail

echo "==> Limpando cache do apt"
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> Zerando logs"
find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /var/log/journal/* || true

echo "==> Removendo chaves de host do SSH (recriadas no primeiro boot)"
rm -f /etc/ssh/ssh_host_*

echo "==> Removendo chaves autorizadas e historico do build"
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
rm -f /home/ubuntu/.bash_history /root/.bash_history

echo "==> Resetando cloud-init para rodar de novo no primeiro boot"
cloud-init clean --logs --seed

echo "==> Removendo identidade de maquina (regerada no boot)"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

echo "==> Garantindo que nenhum segredo ficou na imagem"
rm -f /etc/atlantis/atlantis.env /etc/atlantis/gh-app-key.pem

sync
echo "==> Limpeza concluida"
