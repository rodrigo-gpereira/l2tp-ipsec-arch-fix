# Troubleshooting completo — L2TP/IPsec PSK no Arch Linux

Guia detalhado dos bugs que impedem L2TP/IPsec PSK (xl2tpd + libreswan/
strongSwan) de funcionar no Arch Linux contra um servidor **accel-ppp**,
replicando o padrão clássico do Windows (usuário/senha + PSK, MS-CHAPv2,
criptografia "opcional"). Documentado em ordem — cada sintoma só aparece
depois do anterior estar resolvido.

Pré-requisito: `sudo pacman -S networkmanager-l2tp xl2tpd`, que traz o
`nm-l2tp-service` e, como dependência opcional, o `libreswan` (backend
IPsec padrão do plugin — não `strongswan`, como seria de se esperar vindo
de outras distros).

## Bug 1 — xl2tpd rejeitado pelo accel-ppp (AVP RX Connect Speed)

Sintoma: `Received out of order control packet`, sempre logo após o ICCN.

Causa: o `xl2tpd` inclui um AVP opcional "RX Connect Speed" no ICCN que o
`accel-ppp` rejeita silenciosamente.

Fix: compilar com `-DCONFIG_WATCHDOG_FIREWALL` — ver
[`xl2tpd/PKGBUILD`](../xl2tpd/PKGBUILD) deste repositório. Mesmos caminhos
do pacote oficial do repo `extra`, então `pacman -U` substitui direto, sem
conflito.

(nota: a ferramenta auxiliar `pfc`, que viria do `make` sem alvo
especificado, foi deixada de fora do pacote porque precisa de
`libpcap`/`libpcap-dev` e o NetworkManager não usa ela.)

## Bug 2 — libreswan: bug aberto upstream no XFRM

Com o `libreswan` padrão, IKE fase 1 e fase 2 fecham normalmente:

```
#1: ISAKMP SA established {auth=PRESHARED_KEY ...}
#2: our client subnet returned doesn't match my proposal - us: ... vs them: ...
#2: Allowing questionable (microsoft) proposal anyway
EXPECTATION FAILED: selector_protocol(*dst_client) == client_proto (set_xfrm_selectors() +775 programs/pluto/kernel_xfrm.c)
    [repete várias vezes]
#2: IPsec SA established transport mode {ESPinUDP=>... xfrm=... NATD=...}
```

A SA **estabelece de verdade** (`IPsec SA established transport mode`),
mas o `nm-l2tp-service` reporta `Could not establish IPsec connection.`
~250ms depois, mesmo assim. Motivo: pro backend libreswan, o
`nm-l2tp-service` **só confia no exit code** do comando `ipsec up <uuid>`
(não lê o log) — e o bug faz esse exit code vir errado.

Esse é um bug real e **ainda aberto** no libreswan —
[`libreswan/libreswan#1343`](https://github.com/libreswan/libreswan/issues/1343)
tem um relato com log **idêntico**, mesmo gatilho: o servidor devolve um
client-subnet "questionável" (padrão Microsoft/RRAS-like), o libreswan
aceita via um caminho de compatibilidade, e a validação interna do XFRM
trava. Sem fix confirmado até a versão testada no issue (5.4). **Não dá
pra contornar só mudando configuração do lado do cliente** — é bug de
código no libreswan mesmo.

(Desabilitar PFS — `ipsec-pfs=no` no `vpn.data` — resolve um sintoma
parecido, de timeout total na fase 2, mas não resolve esse bug específico
do exit code. Vale manter `ipsec-pfs=no` de qualquer forma, é mais
compatível com servidores legados.)

**Correção**: trocar pra strongSwan (`sudo pacman -R libreswan` — ou deixe
o pacote `strongswan` deste repo fazer isso automaticamente via
`conflicts`).

## Bug 3 — strongSwan oficial do Arch sem IKEv1

O `strongswan` do repo `extra` (6.1.0) é compilado **sem suporte a
IKEv1** (upstream vem descontinuando o protocolo). L2TP/IPsec PSK é
inteiramente IKEv1 — sem isso, `charon` recusa com:

```
charon[...]: IKE version 1 not supported
```

Confirma vendo se falta o plugin (não existe `libstrongswan-ikev1.so`,
porque IKEv1 não é um plugin — é uma feature compilada no core do
`libcharon` via `--enable-ikev1`):

```bash
pacman -Ql strongswan | grep '\.so$'   # não vai aparecer nada com "ikev1"
```

**Correção**: recompilar com `--enable-ikev1` — ver
[`strongswan-ikev1/PKGBUILD`](../strongswan-ikev1/PKGBUILD) deste
repositório.

Detalhes de empacotamento que valem registrar (cada um causou um erro
diferente até chegar na versão final do PKGBUILD):

- **`--sbindir=/usr/bin` é obrigatório.** O Arch já fez o merge
  `/usr/sbin → /usr/bin` há anos, mas o `./configure` padrão do
  strongSwan ainda usa `/usr/sbin` como caminho *literal* no manifesto do
  pacote. Sem esse override, `pacman -U` recusa com `exists in
  filesystem` pros binários (`charon-systemd`, `ipsec`, `swanctl`) —
  mesmo sendo o mesmo arquivo físico via symlink, porque a *string* do
  caminho no pacote novo não bate com a do pacote antigo.
- **`pkgrel` precisa subir a cada rebuild**, mesmo sem mudar `pkgver` —
  senão o `pacman -U` trata como "reinstalação idêntica" e aplica uma
  checagem de conflito mais rígida que acusa falso positivo nos mesmos
  moldes do item acima.
- **Não adianta separar `--libexecdir` de `--with-ipsecdir`** tentando
  replicar o layout do pacote oficial (`/usr/lib/strongswan/` pros
  executáveis vs `/usr/lib/ipsec/` pros plugins) — na prática, com esse
  `configure.ac`, tudo acaba indo pra `--with-ipsecdir` de qualquer
  jeito. Não vale a pena perseguir paridade exata com o layout oficial;
  só importa não colidir com o que já está instalado (por isso os pontos
  acima).
- Vários pedaços do build hardcodam o default do autotools
  (`${libexecdir}/ipsec` = `/usr/libexec/ipsec`) mesmo com
  `--with-ipsecdir` setado: o script `ipsec` respeita a flag, mas o
  binário `starter` compilado não. O PKGBUILD cobre isso com um symlink
  de compatibilidade (`/usr/libexec/ipsec → /usr/lib/ipsec`) em vez de
  caçar cada lugar que faz isso.

**Atenção ao nome do serviço**: `strongswan.service` é o daemon
`charon-systemd`/swanctl (config moderna, baseada em `.conf`/vici) —
**não** é esse que o `nm-l2tp-service` usa. O que ele precisa é o
`strongswan-starter.service`, que usa o `ipsec.conf` clássico (o mesmo
formato que o `nm-l2tp-service` gera dinamicamente por conexão).

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now strongswan-starter.service
```

## Bug 4 — kl2tpd tem prioridade sobre xl2tpd e não funciona com accel-ppp

Com o IPsec finalmente de pé (`strongSwan IPsec connection is up.`), a
fase L2TP ainda falhava — mas com um sintoma bem diferente do bug 1:
nenhuma resposta chega nem pro primeiro pacote (SCCRQ):

```
nm-l2tp-service[...]: /usr/bin/kl2tpd -config .../kl2tpd.conf
NetworkManager[...]: level=debug tunnel_name=t1 function=transport message=send message_type=avpMsgTypeSccrq
NetworkManager[...]: level=info tunnel_name=t1 function=transport message=retransmit message_type=avpMsgTypeSccrq
    [repete 3x]
NetworkManager[...]: level=error tunnel_name=t1 message="failed to send SCCRQ message" error="transmit of avpMsgTypeSccrq failed after 3 retry attempts"
```

Causa: o pacote `kl2tpd` (implementação alternativa em Go, instalável
separadamente no Arch) existe no sistema, e o `nm-l2tp-service` **sempre
prioriza `kl2tpd` sobre `xl2tpd`** quando o binário existe em algum destes
caminhos fixos (função `nm_find_l2tpd` em `shared/utils.c` do projeto
[`nm-l2tp/NetworkManager-l2tp`](https://github.com/nm-l2tp/NetworkManager-l2tp)):
`/usr/bin/kl2tpd`, `/sbin/kl2tpd`, `/usr/sbin/kl2tpd`,
`/usr/local/sbin/kl2tpd` — **sem nenhuma flag pra forçar `xl2tpd`** mesmo
com `kl2tpd` presente.

Não foi investigado a fundo por que o `kl2tpd` não fecha com esse
servidor accel-ppp especificamente (pode ser outro bug de
interoperabilidade — o `kl2tpd` é bem mais novo e menos testado que o
`xl2tpd`). Como o `xl2tpd` corrigido (bug 1) comprovadamente funciona, a
solução pragmática é remover o `kl2tpd`:

```bash
sudo pacman -R kl2tpd
```

(se não tiver instalado, esse bug nem aparece — o `nm-l2tp-service` já
cai direto pro `xl2tpd`.)

Ressalva: se precisar de um servidor L2TP com gateway IPv6 no futuro (o
`xl2tpd` não suporta — só o `kl2tpd` suporta), vai precisar investigar por
que o `kl2tpd` não fechava com esse servidor accel-ppp, em vez de só
removê-lo.

## Bug 5 (config, não bug de software) — MPPE obrigatório

Com os quatro problemas acima resolvidos, IPsec + túnel L2TP + PPP LCP +
**CHAP autenticam**, mas a conexão ainda cai:

```
pppd[...]: CHAP authentication succeeded
pppd[...]: MPPE required but peer negotiation failed
pppd[...]: Connection terminated.
```

Causa: `require-mppe=yes` no `vpn.data`. Se o padrão original (Windows,
por exemplo) usa "Criptografia de dados: Opcional (conectar mesmo sem
criptografia)", o servidor pode simplesmente não oferecer MPPE — exigir
ele do lado do cliente derruba a conexão.

Correção:

```bash
nmcli connection modify "Minha VPN" -vpn.data "require-mppe=yes"
```

## Resultado esperado

```
pppd[...]: CHAP authentication succeeded
pppd[...]: local  IP address <IP interno>
pppd[...]: remote IP address <IP do gateway L2TP>
pppd[...]: primary   DNS address <DNS 1>
pppd[...]: secondary DNS address <DNS 2>
NetworkManager[...]: policy: set '<nome da conexão>' (ppp0) as default for IPv4 routing and DNS
```

## Checklist de diagnóstico rápido (nessa ordem)

1. `journalctl -u NetworkManager -f` + tentar conectar.
2. IPsec nem fecha / timeout na fase 2 → confirma backend (`pacman -Qi
   libreswan strongswan` — só um dos dois deve estar instalado) e se tem
   `IKE version 1 not supported` (bug 3) ou `EXPECTATION FAILED` +
   `Could not establish IPsec connection` mesmo com `IPsec SA
   established` nos logs (bug 2).
3. IPsec fecha, mas nem o primeiro pacote L2TP (SCCRQ) recebe resposta →
   confirma se é o `kl2tpd` rodando (`nm-l2tp-service[...]: kl2tpd
   started` no log) em vez do `xl2tpd` (bug 4).
4. L2TP fecha chamada, PPP começa, mas trava ~5s depois com "out of order
   control packet" → bug 1 (AVP RX Connect Speed).
5. CHAP autentica mas cai com "MPPE required" → bug 5.

## Nota: Ubuntu

O bug 1 (`xl2tpd` x `accel-ppp`) é idêntico no Ubuntu — mesmo AVP, mesmo
fix (`-DCONFIG_WATCHDOG_FIREWALL`). Os bugs 2, 3 e 4 são específicos do
Arch (empacotamento `libreswan`/`strongswan`/`kl2tpd` do repo `extra`).
