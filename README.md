# L2TP/IPsec PSK no Arch Linux (xl2tpd + strongSwan customizados)

Pacotes customizados e guia de instalação pra fazer **L2TP/IPsec com PSK**
funcionar no Arch Linux via `NetworkManager`/`nmcli`, replicando o padrão
clássico do Windows (usuário/senha + PSK, MS-CHAPv2) contra servidores
**accel-ppp**.

No Arch, os pacotes oficiais do repo `extra` têm dois problemas que
impedem esse cenário de funcionar:

1. **`xl2tpd`** envia um AVP opcional ("RX Connect Speed") no ICCN que o
   `accel-ppp` rejeita silenciosamente — a conexão cai ~5s depois com
   `Received out of order control packet`.
2. **`strongswan`** (6.1.0) é compilado sem suporte a IKEv1 — e L2TP/IPsec
   PSK clássico é inteiramente IKEv1. O backend alternativo, `libreswan`,
   tem um [bug aberto no XFRM](https://github.com/libreswan/libreswan/issues/1343)
   que afeta exatamente esse cenário (client-subnet "questionável" tipo
   Microsoft/RRAS).

Este repositório traz os `PKGBUILD` com os fixes e, na seção
[Releases](../../releases), os pacotes `.pkg.tar.zst` já compilados pra
`x86_64`, pra quem não quiser compilar localmente.

Detalhes completos de cada bug, log de diagnóstico e checklist de
troubleshooting: [`docs/troubleshooting.md`](docs/troubleshooting.md).

## Instalação

### Opção A — compilar localmente (recomendado)

```bash
git clone <URL_DESTE_REPO>
cd l2tp-ipsec-arch-fix
./install.sh
```

O script:

- remove o `kl2tpd`, se estiver instalado (ver bug 4 no guia de
  troubleshooting — ele tem prioridade sobre o `xl2tpd` no
  `nm-l2tp-service` e não funciona com esse servidor accel-ppp);
- instala `networkmanager-l2tp` (dependência base);
- compila e instala o `xl2tpd` customizado (`makepkg -si`);
- compila e instala o `strongswan` customizado — o pacote tem
  `conflicts=(libreswan)`, então o `pacman` remove o `libreswan`
  automaticamente nessa etapa;
- habilita o `strongswan-starter.service` (não confundir com
  `strongswan.service` — ver nota abaixo).

### Opção B — pacote pré-compilado

Baixe os `.pkg.tar.zst` da [página de releases](../../releases) deste
repositório e confira o checksum antes de instalar:

```bash
sha256sum -c SHA256SUMS
sudo pacman -S --needed networkmanager-l2tp   # dependência base
sudo pacman -U ./xl2tpd-1.3.20-1-x86_64.pkg.tar.zst
sudo pacman -U ./strongswan-6.1.0-1-x86_64.pkg.tar.zst
sudo systemctl daemon-reload
sudo systemctl enable --now strongswan-starter.service
```

O `pacman -U` do `strongswan` pede confirmação pra remover o `libreswan`
(conflito declarado no pacote) — confirme com `y`.

> **strongswan-starter vs strongswan.service**: `strongswan.service` é o
> daemon `charon-systemd`/`swanctl` (config moderna, baseada em
> `.conf`/vici) — **não é esse** que o `nm-l2tp-service` usa. O que ele
> precisa é o `strongswan-starter.service`, que lê o `ipsec.conf` clássico
> gerado dinamicamente por conexão.

### Compilando você mesmo, sem o script

```bash
cd xl2tpd && makepkg -si
cd ../strongswan-ikev1 && makepkg -si
```

## Configurando a conexão via nmcli

Depois dos pacotes instalados:

```bash
nmcli connection add type vpn vpn-type l2tp con-name "Minha VPN" \
  vpn.data "gateway=SEU_GATEWAY, user=SEU_USUARIO, ipsec-enabled=yes, \
ipsec-forceencaps=yes, ipsec-pfs=no, machine-auth-type=psk, mru=1400, \
mtu=1400, password-flags=1, refuse-chap=yes, refuse-eap=yes, \
refuse-mschap=yes, refuse-pap=yes, user-auth-type=password, \
ephemeral-port=yes"
```

`ipsec-pfs=no` já incluído (mais compatível com servidores legados) e
**sem** `require-mppe=yes` (só adicione se o servidor exigir MPPE — ver
bug 5 no guia de troubleshooting).

Segredos via editor interativo (não ficam no histórico do shell nem em
`ps aux`):

```
nmcli connection edit "Minha VPN"
nmcli> goto vpn
nmcli vpn> set secrets password = SUA_SENHA, ipsec-psk = SUA_PSK
nmcli vpn> back
nmcli> save
nmcli> quit
```

```bash
nmcli connection up "Minha VPN" --ask
```

(sem `--ask` falha com "No valid secrets" mesmo com os segredos já
salvos, porque `password-flags=1` marca o segredo como agent-owned.)

Acompanhe com `journalctl -u NetworkManager -f` enquanto testa.

### Autoconnect depois de reboot

Com `password-flags=1` (padrão), a senha não fica persistida em disco —
depois de um reboot, `connection.autoconnect=yes` falha silenciosamente
com `No valid secrets`. Isso é esperado, não é bug. Pra autoconnect de
verdade: use `password-flags=0` (senha em texto plano no arquivo da
conexão, menos seguro) ou configure um agente de segredos com a senha em
keyring. Se não quiser autoconnect:

```bash
nmcli connection modify "Minha VPN" connection.autoconnect no
```

## Checklist de diagnóstico rápido

| Sintoma nos logs (`journalctl -u NetworkManager -f`) | Causa | Fix |
|---|---|---|
| IPsec trava em fase 2 / timeout | `libreswan` instalado | trocar pra `strongswan` (Opção A/B acima) |
| `IKE version 1 not supported` | `strongswan` oficial sem IKEv1 | usar o pacote deste repo |
| `EXPECTATION FAILED` + `Could not establish IPsec connection` mesmo com `IPsec SA established` | bug do XFRM no `libreswan` ([#1343](https://github.com/libreswan/libreswan/issues/1343)) | trocar pra `strongswan` |
| IPsec fecha, mas SCCRQ (L2TP) não recebe resposta | `kl2tpd` tem prioridade sobre `xl2tpd` | `sudo pacman -R kl2tpd` |
| `Received out of order control packet` ~5s após ICCN | `xl2tpd` oficial rejeitado pelo `accel-ppp` | usar o pacote deste repo |
| `CHAP authentication succeeded` seguido de `MPPE required but peer negotiation failed` | `require-mppe=yes` no `vpn.data` com servidor de criptografia opcional | `nmcli connection modify "Minha VPN" -vpn.data "require-mppe=yes"` |

Detalhes, logs completos e explicação de cada bug:
[`docs/troubleshooting.md`](docs/troubleshooting.md).

## Pendências / ressalvas

- `pacman -Syu` pode trazer `xl2tpd` ou `strongswan` novo do repo `extra`
  e reverter esses pacotes customizados — confira depois de updates
  grandes (`pacman -Qi xl2tpd strongswan`, veja se a descrição/pkgrel
  ainda é a customizada).
- Servidor com gateway IPv6: `xl2tpd` não suporta (só o `kl2tpd`
  suportaria, mas ele não fechou com o accel-ppp testado aqui — não
  investigado a fundo).

## Licença

Os `PKGBUILD` deste repositório são disponibilizados sob MIT (ver
[`LICENSE`](LICENSE)). O software empacotado (`xl2tpd`, `strongSwan`)
mantém suas próprias licenças upstream (GPL-2.0).
