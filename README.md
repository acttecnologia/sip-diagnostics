# 🔧 ACT Tecnologia - SIP Diagnostic Tool

<div align="center">

![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Debian](https://img.shields.io/badge/Debian-Ubuntu-A81D33?style=for-the-badge&logo=debian&logoColor=white)
![SIP](https://img.shields.io/badge/Protocol-SIP-0078D7?style=for-the-badge)
![License](https://img.shields.io/badge/License-GPL%20v3-blue?style=for-the-badge)

**Ferramenta interativa de diagnóstico completo de conectividade SIP.**  
*Interactive tool for complete SIP connectivity diagnostics.*

</div>

---

## Português 🇧🇷

### Visão Geral

O `sip_test.sh` é uma ferramenta de linha de comando desenvolvida pela **ACT Tecnologia** para diagnóstico completo de conectividade SIP em redes de clientes. Ideal para técnicos de campo que precisam identificar rapidamente a origem de problemas de voz sobre IP.

A ferramenta detecta e analisa:
- Problemas de rede local (gateway, roteamento)
- Problemas no link de internet
- Latência, jitter e perda de pacotes UDP (RTP)
- Registro SIP e autenticação
- Sinalização SIP (OPTIONS, REGISTER, INVITE)
- Persistência e estabilidade da conexão SIP ao longo do tempo

### Funcionalidades

| Recurso | Descrição |
|---|---|
| 🌐 **Baseline de rede** | Ping para gateway, Google (8.8.8.8), Cloudflare (1.1.1.1), ACT Cloud (187.110.160.254) e servidor SIP |
| 📡 **Conectividade ICMP** | Ping com análise de perda e jitter |
| 🔌 **Porta SIP** | Verificação de acesso UDP/5060 via nmap |
| 🎵 **Qualidade RTP** | Simulação de tráfego UDP na porta RTP com hping3, medindo perda e jitter real |
| 🤝 **Handshake SIP** | Envio de SIP OPTIONS e análise de resposta |
| 🔑 **Registro SIP** | REGISTER com usuário, senha e expiração configurável |
| 📞 **Chamada teste** | INVITE para ramal de eco `*43`, verificando sinalização fim a fim |
| ⏱ **Persistência** | Monitoramento contínuo com OPTIONS periódicos durante N minutos |
| 🛣 **Traceroute** | Mapeamento do caminho de rede até o servidor SIP |
| 📄 **Relatório TXT** | Exportação automática do resultado completo para arquivo |
| 🔒 **Anti-flood** | Delays entre testes para evitar banimento via fail2ban |
| ⚙️ **Auto-instalação** | Instala dependências ausentes automaticamente (apt) |

### Níveis de Teste

```
[1] Básico    - Ping + Porta SIP + SIP OPTIONS
[2] Médio     - Básico + Baseline + RTP/Jitter + Traceroute
[3] Completo  - Médio + REGISTER + INVITE + Persistência + TLS
```

### Pré-requisitos

- Sistema Debian/Ubuntu (ou derivados)
- Acesso `sudo` (para instalação de dependências e hping3)
- Ferramentas instaladas automaticamente se ausentes:
  - `sipsak`, `hping3`, `nmap`, `traceroute`, `sngrep`, `openssl`, `dnsutils`, `bc`, `iperf3`

### Instalação

```bash
git clone https://github.com/acttecnologia/sip-diagnostics.git
cd sip-diagnostics
chmod +x sip_test.sh
./sip_test.sh
```

### Uso

```bash
./sip_test.sh
```

O script é totalmente interativo. Ao iniciar, ele solicita:

1. **Idioma** - Português ou English
2. **IP do servidor SIP** - ex: `187.110.160.184`
3. **Porta SIP** - padrão `5060`
4. **Nível de teste** - 1 (Básico), 2 (Médio) ou 3 (Completo)
5. **Duração do teste de persistência** - padrão 300 segundos
6. **Credenciais SIP** - usuário, senha e domínio (necessário para REGISTER/INVITE)
7. **Destino da chamada teste** - padrão `*43` (ramal de eco padrão Asterisk)
8. **Gerar relatório TXT** - salvo com timestamp no diretório atual

### Exemplo de Saída

```
══════════════════════════════════════════════
  Baseline de Rede (Gateway / Internet)
══════════════════════════════════════════════
  Destino                IP                Perda     RTT avg    Status
  ────────────────────────────────────────────────────────────────────
  Gateway local          192.168.1.1       0%        1.2ms      [✔] OK
  Google DNS             8.8.8.8           0%        12.4ms     [✔] OK
  Cloudflare DNS         1.1.1.1           0%        11.8ms     [✔] OK
  ACT Cloud              187.110.160.254   0%        18.3ms     [✔] OK
  Servidor SIP           187.110.160.184   0%        18.7ms     [✔] OK

  [✔] Gateway e internet OK

══════════════════════════════════════════════
  Qualidade RTP / Jitter UDP
══════════════════════════════════════════════
  [→] Enviando 100 pacotes UDP para 187.110.160.184:10000...
  [→] Pacotes enviados : 100
  [→] Respostas ICMP   : 97
  [→] Perda estimada   : 3%
  [→] Jitter (avg-min) : 2.3 ms
  [✔] Jitter excelente para VoIP

══════════════════════════════════════════════
  Teste SIP OPTIONS
══════════════════════════════════════════════
  [✔] SIP OPTIONS respondido, servidor ativo
  [→] Resposta: 200 OK

══════════════════════════════════════════════
  Registro SIP (REGISTER)
══════════════════════════════════════════════
  [✔] REGISTER aceito (200 OK)

══════════════════════════════════════════════
  Teste de Chamada INVITE (*43)
══════════════════════════════════════════════
  [✔] INVITE 200 OK, chamada estabelecida
```

### NAT Traversal

O script trata NAT automaticamente usando `rport;alias` no cabeçalho Via do SIP (via `sipsak`), permitindo que o servidor SIP preencha o IP público e a porta corretos sem necessidade de configuração manual.

### Detecção de fail2ban

O script detecta quando o IP foi banido pelo fail2ban do servidor Asterisk (manifesta-se como "Connection refused" nas respostas SIP) e exibe aviso específico. Delays foram calibrados entre os blocos de teste para evitar o acionamento do ban durante a execução.

### Relatório

O relatório é salvo em formato texto simples com timestamp:

```
sip_report_20250414_143022.txt
```

Pode ser enviado diretamente por e-mail ou WhatsApp para análise remota.

### Observações sobre RTP / Jitter

A medição de jitter usa `avg - min` de RTT (em vez de `max - min`) como proxy mais estável, resistente a outliers causados pelo rate limiting de ICMP do sistema operacional (`net.ipv4.icmp_ratelimit`). A "perda" UDP na porta RTP pode aparecer alta (30-80%) em servidores que limitam respostas ICMP Port Unreachable. Isso **não** indica perda real no fluxo RTP.

---

## English 🇺🇸

### Overview

`sip_test.sh` is a command-line tool developed by **ACT Tecnologia** for complete SIP connectivity diagnostics on customer networks. Designed for field technicians who need to quickly identify the source of VoIP issues.

The tool detects and analyzes:
- Local network problems (gateway, routing)
- Internet link issues
- UDP latency, jitter and packet loss (RTP)
- SIP registration and authentication
- SIP signaling (OPTIONS, REGISTER, INVITE)
- SIP connection persistence and stability over time

### Features

| Feature | Description |
|---|---|
| 🌐 **Network baseline** | Ping to gateway, Google (8.8.8.8), Cloudflare (1.1.1.1), ACT Cloud (187.110.160.254) and SIP server |
| 📡 **ICMP connectivity** | Ping with loss and jitter analysis |
| 🔌 **SIP port check** | UDP/5060 access verification via nmap |
| 🎵 **RTP quality** | UDP traffic simulation on RTP port with hping3, measuring real loss and jitter |
| 🤝 **SIP handshake** | SIP OPTIONS request and response analysis |
| 🔑 **SIP registration** | REGISTER with configurable user, password and expiry |
| 📞 **Test call** | INVITE to echo extension `*43`, verifying end-to-end signaling |
| ⏱ **Persistence** | Continuous monitoring with periodic OPTIONS for N minutes |
| 🛣 **Traceroute** | Network path mapping to SIP server |
| 📄 **TXT report** | Automatic export of full results to file |
| 🔒 **Anti-flood** | Delays between tests to prevent fail2ban bans |
| ⚙️ **Auto-install** | Automatically installs missing dependencies (apt) |

### Test Levels

```
[1] Basic     - Ping + SIP Port + SIP OPTIONS
[2] Medium    - Basic + Baseline + RTP/Jitter + Traceroute
[3] Full      - Medium + REGISTER + INVITE + Persistence + TLS
```

### Requirements

- Debian/Ubuntu system (or derivatives)
- `sudo` access (for dependency installation and hping3)
- Tools auto-installed if missing:
  - `sipsak`, `hping3`, `nmap`, `traceroute`, `sngrep`, `openssl`, `dnsutils`, `bc`, `iperf3`

### Installation

```bash
git clone https://github.com/acttecnologia/sip-diagnostics.git
cd sip-diagnostics
chmod +x sip_test.sh
./sip_test.sh
```

### Usage

```bash
./sip_test.sh
```

The script is fully interactive. At startup it asks for:

1. **Language** - Português or English
2. **SIP server IP** - e.g. `187.110.160.184`
3. **SIP port** - default `5060`
4. **Test level** - 1 (Basic), 2 (Medium) or 3 (Full)
5. **Persistence test duration** - default 300 seconds
6. **SIP credentials** - user, password and domain (required for REGISTER/INVITE)
7. **Test call destination** - default `*43` (standard Asterisk echo extension)
8. **Generate TXT report** - saved with timestamp in current directory

### NAT Traversal

The script handles NAT traversal automatically using `rport;alias` in the SIP Via header (via `sipsak`), which allows the SIP server to fill in the correct public IP and port without requiring manual configuration.

### fail2ban Detection

The script detects when the client IP has been banned by the Asterisk server's fail2ban (manifests as "Connection refused" in SIP responses) and displays a specific warning. Delays between test blocks are calibrated to avoid triggering the ban during execution.

### Report

The report is saved as plain text with a timestamp:

```
sip_report_20250414_143022.txt
```

Can be sent directly via email or messaging apps for remote analysis.

### RTP / Jitter Notes

The jitter measurement uses `avg - min` RTT (rather than `max - min`) as a more stable proxy, resistant to outliers caused by OS ICMP rate limiting (`net.ipv4.icmp_ratelimit`). UDP "loss" at the RTP port is expected to appear high (30-80%) on servers that rate-limit ICMP Port Unreachable responses. This does **not** indicate actual RTP stream loss.

---

## Arquitetura / Architecture

```
sip_test.sh
|
+-- install_deps()          Verifica e instala dependências
+-- detect_local_ip()       Detecta IP de saída via roteamento
|
+-- test_baseline()         Ping para gateway, DNS públicos, ACT Cloud, SIP
+-- test_ping()             Ping detalhado para servidor SIP
+-- test_port_udp()         nmap UDP 5060
+-- test_jitter()           hping3 UDP para porta RTP (jitter/loss)
+-- test_traceroute()       Traceroute até servidor SIP
|
+-- test_sip_options()      SIP OPTIONS (sipsak)
+-- test_register()         SIP REGISTER com autenticação
+-- test_invite()           SIP INVITE para *43 (echo test)
+-- test_sip_persistent()   OPTIONS periódicos por N minutos
+-- test_tls()              Handshake TLS/SRTP (openssl s_client)
```

---

## Licença / License

GPL v3 © ACT Tecnologia

Uso e distribuição permitidos, mas qualquer modificação deve ser disponibilizada sob a mesma licença. Uso comercial do código por terceiros exige que o fonte permaneça aberto.

Use and distribution are allowed, but any modification must be released under the same license. Commercial use of the code by third parties requires keeping the source open.
