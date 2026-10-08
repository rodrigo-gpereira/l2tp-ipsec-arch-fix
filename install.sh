#!/usr/bin/env bash
# Instala os pacotes customizados (xl2tpd + strongswan com IKEv1) necessários
# pra L2TP/IPsec PSK funcionar no Arch Linux contra servidores accel-ppp.
# Ver README.md pra detalhes de cada bug corrigido.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v makepkg &>/dev/null; then
  echo "makepkg não encontrado — isso precisa ser executado num sistema Arch Linux (ou derivado)." >&2
  exit 1
fi

if [[ $EUID -eq 0 ]]; then
  echo "Não execute como root — makepkg se recusa a compilar como root. Execute como usuário normal (vai pedir sudo quando precisar)." >&2
  exit 1
fi

echo "==> Removendo kl2tpd, se instalado (bug 4: nm-l2tp-service sempre prioriza kl2tpd sobre xl2tpd quando ambos existem)"
if pacman -Qi kl2tpd &>/dev/null; then
  sudo pacman -R --noconfirm kl2tpd
else
  echo "    kl2tpd não está instalado, ok."
fi

echo "==> Garantindo dependências base (networkmanager-l2tp)"
sudo pacman -S --needed --noconfirm networkmanager-l2tp

echo "==> Compilando e instalando xl2tpd customizado (-DCONFIG_WATCHDOG_FIREWALL)"
(cd "$REPO_DIR/xl2tpd" && makepkg -si --noconfirm)

echo "==> Compilando e instalando strongswan customizado (--enable-ikev1)"
echo "    Isso vai remover o libreswan automaticamente via 'conflicts' do pacote (bug 2: bug aberto no XFRM do libreswan)."
(cd "$REPO_DIR/strongswan-ikev1" && makepkg -si --noconfirm)

echo "==> Habilitando o serviço correto (strongswan-starter, não strongswan/charon-systemd)"
sudo systemctl daemon-reload
sudo systemctl enable --now strongswan-starter.service

cat <<'EOF'

Pronto. Os pacotes customizados estão instalados.

Falta configurar a conexão em si — ver "Configurando a conexão via nmcli"
no README.md deste repositório (não faz parte deste script porque depende
dos dados da sua VPN: gateway, usuário, senha, PSK).

Lembre-se do bug 5 (config, não bug de software): se o servidor usa
criptografia "opcional", NÃO defina require-mppe=yes no vpn.data.
EOF
