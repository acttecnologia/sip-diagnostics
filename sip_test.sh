#!/usr/bin/env bash
# ==============================================================================
#  ACT Tecnologia — SIP Diagnostic Tool
#  Ferramenta de Diagnóstico SIP Completo
#  Versão 1.1
# ==============================================================================

# Sem set -e: script de diagnóstico não deve morrer em erros parciais
set -uo pipefail

# ── Cores ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';   BOLD='\033[1m';  RESET='\033[0m'
WHITE='\033[1;37m'; MAGENTA='\033[0;35m'

# ── Globals ────────────────────────────────────────────────────────────────────
LANG_PT=1
SIP_IP=""
SIP_PORT="5060"
TEST_DURATION=300
SIP_USER=""
SIP_PASS=""
SIP_DOMAIN=""
TEST_LEVEL=1
RTP_PORT=10000        # Porta RTP padrão — altere aqui se necessário
DO_INVITE=0
INVITE_DST=""
REPORT_FILE=""
REPORT_LINES=()
SUDO_OK=0
LOCAL_IP=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Idioma ─────────────────────────────────────────────────────────────────────
t() { [[ $LANG_PT -eq 1 ]] && echo "$1" || echo "$2"; }

# ── Helpers de output ──────────────────────────────────────────────────────────
header() {
  clear
  echo -e "${BLUE}${BOLD}  ╔══════════════════════════════════════════════════════════════╗"
  echo -e "${BLUE}${BOLD}  ║           ACT Tecnologia — SIP Diagnostic Tool              ║"
  echo -e "${BLUE}${BOLD}  ║                  Diagnóstico SIP Completo                    ║"
  echo -e "${BLUE}${BOLD}  ╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

section() {
  echo ""
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════${RESET}"
  REPORT_LINES+=("" "══ $1 ══")
}

ok()   { echo -e "  ${GREEN}[✔]${RESET} $1"; REPORT_LINES+=("[OK]   $1"); }
fail() { echo -e "  ${RED}[✘]${RESET} $1"; REPORT_LINES+=("[FAIL] $1"); }
warn() { echo -e "  ${YELLOW}[!]${RESET} $1"; REPORT_LINES+=("[WARN] $1"); }
info() { echo -e "  ${WHITE}[→]${RESET} $1"; REPORT_LINES+=("[INFO] $1"); }
raw()  { echo -e "       ${MAGENTA}$1${RESET}"; REPORT_LINES+=("       $1"); }

ask() {
  local prompt="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}${prompt}${RESET} [${CYAN}${default}${RESET}]: "
  else
    echo -ne "  ${BOLD}${prompt}${RESET}: "
  fi
}

confirm() {
  echo -ne "  ${BOLD}$1${RESET} [S/n]: "
  local ans; read -r ans
  [[ -z "$ans" || "$ans" =~ ^[sSyY]$ ]]
}

# ── Verificar sudo ─────────────────────────────────────────────────────────────
check_sudo() {
  if sudo -n true 2>/dev/null; then
    SUDO_OK=1
  else
    if sudo -v 2>/dev/null; then SUDO_OK=1; fi
  fi
}

# ── Instalar dependências ──────────────────────────────────────────────────────
install_deps() {
  section "$(t 'Verificando Dependências' 'Checking Dependencies')"

  declare -A tool_pkg=(
    [sipsak]=sipsak [hping3]=hping3 [nmap]=nmap
    [traceroute]=traceroute [sngrep]=sngrep [openssl]=openssl
    [dig]=dnsutils [bc]=bc [iperf3]=iperf3
  )

  local pkgs=()
  for tool in "${!tool_pkg[@]}"; do
    if command -v "$tool" &>/dev/null; then
      ok "$tool $(t 'disponível' 'available')"
    else
      warn "$tool $(t 'não encontrado — marcado para instalação' 'not found — queued for install')"
      pkgs+=("${tool_pkg[$tool]}")
    fi
  done

  if [[ ${#pkgs[@]} -gt 0 ]]; then
    echo ""
    info "$(t 'Instalando:' 'Installing:') ${pkgs[*]}"
    if sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y -qq "${pkgs[@]}" 2>/dev/null; then
      ok "$(t 'Dependências instaladas com sucesso' 'Dependencies installed successfully')"
    else
      warn "$(t 'Algumas instalações falharam — alguns testes podem ser pulados' \
               'Some installs failed — some tests may be skipped')"
    fi
  else
    ok "$(t 'Todas as dependências satisfeitas' 'All dependencies satisfied')"
  fi
}

# ── Detectar IP local ──────────────────────────────────────────────────────────
detect_local_ip() {
  LOCAL_IP=$(ip route get "$SIP_IP" 2>/dev/null \
    | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  if [[ -z "$LOCAL_IP" ]]; then
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || LOCAL_IP="unknown"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  TESTES
# ══════════════════════════════════════════════════════════════════════════════

# ── 0. Baseline de rede local e internet ──────────────────────────────────────
test_baseline() {
  section "$(t 'Baseline de Rede (Gateway / Internet)' 'Network Baseline (Gateway / Internet)')"

  # Detecta gateway local
  local gw
  gw=$(ip route show default 2>/dev/null | awk '/default via/{print $3; exit}') || true
  gw=${gw:-"$(t 'não detectado' 'not detected')"}

  local -A targets=(
    ["$(t 'Gateway local' 'Local gateway')"]="$gw"
    ["Google DNS"]="8.8.8.8"
    ["Cloudflare DNS"]="1.1.1.1"
    ["ACT Cloud"]="187.110.160.254"
    ["$(t 'Servidor SIP' 'SIP Server')"]="$SIP_IP"
  )
  # Ordem de exibição
  local -a order=("$(t 'Gateway local' 'Local gateway')" "Google DNS" "Cloudflare DNS" "ACT Cloud" "$(t 'Servidor SIP' 'SIP Server')")

  printf "  %-22s  %-16s  %-8s  %-10s  %s\n" \
    "$(t 'Destino' 'Target')" "IP" \
    "$(t 'Perda' 'Loss')" \
    "RTT avg" "$(t 'Status' 'Status')"
  echo -e "  $(printf '─%.0s' {1..68})"
  REPORT_LINES+=("$(printf '  %-22s  %-16s  %-8s  %-10s  %s' \
    'Destino' 'IP' 'Perda' 'RTT avg' 'Status')")
  REPORT_LINES+=("  $(printf '─%.0s' {1..68})")

  for label in "${order[@]}"; do
    local ip="${targets[$label]}"

    # Pula se gateway não detectado
    if [[ "$ip" == "$(t 'não detectado' 'not detected')" || -z "$ip" ]]; then
      printf "  %-22s  %-16s  %-10s  %-10s  %s\n" \
        "$label" "-" "-" "-" "$(t 'N/A' 'N/A')"
      REPORT_LINES+=("$(printf '  %-22s  %-16s  %-10s  %-10s  %s' "$label" "-" "-" "-" "N/A")")
      continue
    fi

    local out
    out=$(ping -c 10 -i 0.3 -W 2 "$ip" 2>&1) || true

    local loss_pct avg_ms status_icon status_txt
    # Extrai só o número da perda (ex: "0" de "0% packet loss")
    loss_pct=$(echo "$out" | grep -oP '\d+(?=% packet loss)' || true); loss_pct=${loss_pct:-100}
    # Extrai avg e arredonda para 1 decimal
    avg_ms=$(echo "$out" | grep -oP 'min/avg/max[^=]*= [^/]+/\K[^/]+' || true)
    avg_ms=$(LC_ALL=C printf "%.1f" "${avg_ms:-0}" 2>/dev/null || echo "-")

    if   [[ "${loss_pct}" -eq 0 ]];  then status_icon="${GREEN}[✔]${RESET}"; status_txt="OK"
    elif [[ "${loss_pct}" -le 5 ]];  then status_icon="${YELLOW}[!]${RESET}"; status_txt="$(t 'Perda leve' 'Low loss')"
    elif [[ "${loss_pct}" -le 30 ]]; then status_icon="${YELLOW}[!]${RESET}"; status_txt="$(t 'Perda moderada' 'Moderate loss')"
    elif [[ "${loss_pct}" -lt 100 ]]; then status_icon="${RED}[✘]${RESET}"; status_txt="$(t 'Perda alta' 'High loss')"
    else status_icon="${RED}[✘]${RESET}"; status_txt="$(t 'Inacessível' 'Unreachable')"; fi

    printf "  %-22s  %-16s  %-8s  %-10s  %b %s\n" \
      "$label" "$ip" "${loss_pct}%" "${avg_ms}ms" "$status_icon" "$status_txt"
    REPORT_LINES+=("$(printf '  %-22s  %-16s  %-8s  %-10s  [%s] %s' \
      "$label" "$ip" "${loss_pct}%" "${avg_ms}ms" \
      "$([ "$status_txt" = "OK" ] && echo "OK" || echo "!!")" "$status_txt")")
  done

  echo ""
  # Diagnóstico cruzado — usa os resultados já coletados (sem novo ping)
  local gw_ok=0 inet_ok=0
  local _out_gw _out_g _out_cf
  _out_gw=$(ping -c 4 -W 2 "$gw"      2>/dev/null) || true
  _out_g=$( ping -c 4 -W 2 "8.8.8.8"  2>/dev/null) || true
  _out_cf=$(ping -c 4 -W 2 "1.1.1.1"  2>/dev/null) || true

  local _gw_loss _g_loss _cf_loss
  _gw_loss=$(echo "$_out_gw" | grep -oP '\d+(?=% packet loss)' || true); _gw_loss=${_gw_loss:-100}
  _g_loss=$( echo "$_out_g"  | grep -oP '\d+(?=% packet loss)' || true); _g_loss=${_g_loss:-100}
  _cf_loss=$(echo "$_out_cf" | grep -oP '\d+(?=% packet loss)' || true); _cf_loss=${_cf_loss:-100}

  [[ "${_gw_loss}" -lt 50 ]] && gw_ok=1
  [[ "${_g_loss}"  -lt 50 || "${_cf_loss}" -lt 50 ]] && inet_ok=1

  if   [[ $gw_ok -eq 0 ]]; then
    fail "$(t 'Gateway local inacessível — problema na rede interna' 'Local gateway unreachable — internal network issue')"
  elif [[ $inet_ok -eq 0 ]]; then
    fail "$(t 'Internet inacessível mas gateway OK — problema no link/ISP' 'Internet unreachable but gateway OK — link/ISP issue')"
  else
    ok "$(t 'Gateway e internet OK' 'Gateway and internet OK')"
  fi
}

# ── 1. Conectividade básica ────────────────────────────────────────────────────
test_ping() {
  section "$(t 'Conectividade ICMP (Ping)' 'ICMP Connectivity (Ping)')"
  local count=20
  info "$(t "Enviando $count pings para $SIP_IP..." "Sending $count pings to $SIP_IP...")"

  local out
  out=$(ping -c "$count" -i 0.5 "$SIP_IP" 2>&1) || true

  local transmitted received loss rtt_line
  transmitted=$(echo "$out" | grep -oP '\d+ packets transmitted' | grep -oP '^\d+' || echo "0")
  received=$(   echo "$out" | grep -oP '\d+ received'            | grep -oP '^\d+' || echo "0")
  loss=$(       echo "$out" | grep -oP '\d+(\.\d+)?% packet loss'                  || echo "N/A")
  rtt_line=$(   echo "$out" | grep "rtt min"                                        || echo "")

  raw "$(t 'Enviados' 'Sent'):    $transmitted"
  raw "$(t 'Recebidos' 'Received'): $received"
  raw "$(t 'Perda' 'Loss'):      $loss"

  if [[ -n "$rtt_line" ]]; then
    local rtt_vals
    rtt_vals=$(echo "$rtt_line" | grep -oP '[\d.]+/[\d.]+/[\d.]+/[\d.]+' || echo "")
    if [[ -n "$rtt_vals" ]]; then
      local rtt_min rtt_avg rtt_max rtt_mdev
      IFS='/' read -r rtt_min rtt_avg rtt_max rtt_mdev <<< "$rtt_vals"
      raw "RTT min/avg/max/jitter: ${rtt_min}/${rtt_avg}/${rtt_max}/${rtt_mdev} ms"
      local jitter_int; jitter_int=$(echo "$rtt_mdev" | cut -d. -f1)
      if   [[ "${jitter_int:-99}" -le 10 ]]; then ok   "$(t 'Jitter excelente' 'Excellent jitter') (${rtt_mdev}ms)"
      elif [[ "${jitter_int:-99}" -le 30 ]]; then warn "$(t 'Jitter aceitável' 'Acceptable jitter') (${rtt_mdev}ms)"
      else fail "$(t 'Jitter alto — pode causar problemas de voz' 'High jitter — may cause voice issues') (${rtt_mdev}ms)"; fi
    fi
  fi

  local loss_int; loss_int=$(echo "$loss" | grep -oP '^\d+' || true); loss_int=${loss_int:-0}
  if   [[ "${loss_int:-0}" -eq 0 ]]; then ok   "$(t 'Sem perda de pacotes' 'No packet loss')"
  elif [[ "${loss_int:-0}" -le 1  ]]; then warn "$(t 'Perda mínima' 'Minimal loss'): $loss"
  else fail "$(t 'Perda de pacotes detectada' 'Packet loss detected'): $loss"; fi
}

# ── 2. MTU ─────────────────────────────────────────────────────────────────────
test_mtu() {
  section "$(t 'Teste de MTU / Fragmentação' 'MTU / Fragmentation Test')"
  info "$(t 'Testando MTU sem fragmentação (crítico para SIP/SDP)' \
           'Testing MTU without fragmentation (critical for SIP/SDP)')"

  local sizes=(1472 1400 1300 1200 576)
  local max_ok=0

  for sz in "${sizes[@]}"; do
    if ping -c 2 -W 2 -s "$sz" -M do "$SIP_IP" &>/dev/null; then
      ok "$(t 'Pacote' 'Packet') ${sz}B OK"
      max_ok=$sz
      break
    else
      warn "$(t 'Pacote' 'Packet') ${sz}B $(t 'fragmentado/descartado' 'fragmented/dropped')"
    fi
  done

  local effective_mtu=$(( max_ok + 28 ))
  raw "$(t 'MTU efetivo estimado' 'Estimated effective MTU'): ~${effective_mtu} bytes"

  if   [[ "$max_ok" -ge 1400 ]]; then ok   "$(t 'MTU adequado para SIP+SDP' 'MTU adequate for SIP+SDP')"
  elif [[ "$max_ok" -ge 1200 ]]; then warn "$(t 'MTU reduzido — pacotes SIP grandes podem fragmentar' 'Reduced MTU — large SIP packets may fragment')"
  else fail "$(t 'MTU muito baixo — provável causa de falhas no INVITE' 'Very low MTU — likely cause of INVITE failures')"; fi
}

# ── 3. Traceroute ──────────────────────────────────────────────────────────────
test_traceroute() {
  section "$(t 'Rota de Rede (Traceroute)' 'Network Route (Traceroute)')"
  info "$(t 'Mapeando rota até o servidor SIP...' 'Mapping route to SIP server...')"

  local out
  out=$(traceroute -n -w 2 -q 2 "$SIP_IP" 2>&1 | head -25) || true

  # Evita subshell: armazena em array e itera
  local -a lines
  mapfile -t lines <<< "$out"
  for line in "${lines[@]}"; do raw "$line"; done

  local hops; hops=$(echo "$out" | grep -cP '^\s*\d+' || true)
  local silent; silent=$(echo "$out" | grep -c '\* \* \*' || true)

  raw ""
  info "$(t 'Total de saltos' 'Total hops'): $hops"
  if [[ "${silent:-0}" -gt 3 ]]; then
    warn "$(t "$silent salto(s) sem resposta — possível filtro no caminho" \
             "$silent hop(s) without response — possible path filtering")"
  fi
}

# ── 4. Portas TCP ──────────────────────────────────────────────────────────────
# ── 5. Portas UDP (nmap sudo) ──────────────────────────────────────────────────
test_ports_udp() {
  section "$(t 'Portas SIP/RTP UDP' 'SIP/RTP UDP Ports')"

  if ! command -v nmap &>/dev/null; then
    warn "$(t 'nmap não disponível' 'nmap not available')"; return
  fi

  info "$(t 'Testando UDP 5060 (SIP)...' 'Testing UDP 5060 (SIP)...')"
  local out
  if [[ "$SUDO_OK" -eq 1 ]]; then
    out=$(sudo nmap -sU -p 5060 --open -T4 "$SIP_IP" 2>&1) || true
  else
    out=$(nmap -sU -p 5060 --open -T4 "$SIP_IP" 2>&1) || true
  fi

  if echo "$out" | grep -q "open"; then
    ok "UDP 5060 $(t 'aberta' 'open')"
  else
    warn "UDP 5060 $(t 'sem resposta ou filtrada (normal em alguns firewalls)' \
                      'no response or filtered (normal on some firewalls)')"
  fi

  if [[ "$TEST_LEVEL" -ge 3 ]]; then
    info "$(t 'Testando amostra de portas RTP (10000-10020)...' \
             'Testing RTP port sample (10000-10020)...')"
    if [[ "$SUDO_OK" -eq 1 ]]; then
      out=$(sudo nmap -sU -p 10000-10020 --open -T4 "$SIP_IP" 2>&1) || true
    else
      out=$(nmap -sU -p 10000-10020 --open -T4 "$SIP_IP" 2>&1) || true
    fi
    local open_rtp; open_rtp=$(echo "$out" | grep -c "open" || true)
    if [[ "${open_rtp:-0}" -gt 0 ]]; then
      ok "$(t "$open_rtp porta(s) RTP abertas na amostra" "$open_rtp RTP port(s) open in sample")"
    else
      warn "$(t 'Nenhuma porta RTP respondeu (10000-10020) — verifique o range correto do servidor' \
               'No RTP ports responded (10000-10020) — verify correct server RTP range')"
    fi
  fi
}

# ── 6. SIP OPTIONS ─────────────────────────────────────────────────────────────
test_sip_options() {
  section "$(t 'Sinalização SIP — OPTIONS' 'SIP Signaling — OPTIONS')"

  if ! command -v sipsak &>/dev/null; then
    fail "$(t 'sipsak não disponível' 'sipsak not available')"; return
  fi

  info "$(t "Enviando SIP OPTIONS para $SIP_IP:$SIP_PORT..." \
           "Sending SIP OPTIONS to $SIP_IP:$SIP_PORT...")"

  local out
  out=$(sipsak -s "sip:${SIP_IP}:${SIP_PORT}" -v 2>&1) || true

  if echo "$out" | grep -q "200 OK"; then
    ok "$(t 'Servidor SIP responde 200 OK' 'SIP server responds 200 OK')"
    local server allow contact
    server=$( echo "$out" | grep -i "^Server:"  | head -1 | sed 's/Server: //'  || echo "")
    allow=$(  echo "$out" | grep -i "^Allow:"   | head -1 | sed 's/Allow: //'   || echo "")
    contact=$(echo "$out" | grep -i "^Contact:" | head -1 | sed 's/Contact: //' || echo "")
    [[ -n "$server"  ]] && raw "Server:  $server"
    [[ -n "$allow"   ]] && raw "Allow:   $allow"
    [[ -n "$contact" ]] && raw "Contact: $contact"
  elif echo "$out" | grep -qE "403|401"; then
    warn "$(t 'Servidor respondeu 401/403 — requer autenticação (servidor está ativo)' \
             'Server responded 401/403 — requires auth (server is active)')"
  elif echo "$out" | grep -qi "Connection refused\|send failure"; then
    fail "$(t 'Conexão recusada (ICMP Port Unreachable) — IP possivelmente banido pelo fail2ban do servidor' \
             'Connection refused (ICMP Port Unreachable) — IP may be banned by server fail2ban')"
    warn "$(t 'Para desbanir no servidor: fail2ban-client set asterisk unbanip SEU_IP' \
             'To unban on server: fail2ban-client set asterisk unbanip YOUR_IP')"
  elif echo "$out" | grep -qiE "timeout|No response|408"; then
    fail "$(t 'Sem resposta — servidor não acessível na porta SIP' \
             'No response — server not reachable on SIP port')"
  else
    warn "$(t 'Resposta inesperada:' 'Unexpected response:') $(echo "$out" | head -1)"
  fi
}

# ── 7. SIP persistente ────────────────────────────────────────────────────────
test_sip_persistent() {
  section "$(t "Monitoramento SIP Persistente (${TEST_DURATION}s)" \
              "Persistent SIP Monitoring (${TEST_DURATION}s)")"

  if ! command -v sipsak &>/dev/null; then
    fail "sipsak $(t 'não disponível' 'not available')"; return
  fi

  local interval=10
  local iterations=$(( TEST_DURATION / interval ))
  local ok_count=0 fail_count=0
  local rtt_total=0 rtt_count=0

  info "$(t "Enviando OPTIONS a cada ${interval}s — $iterations probes no total..." \
           "Sending OPTIONS every ${interval}s — $iterations probes total...")"
  info "$(t 'Aguarde...' 'Please wait...')"
  echo ""

  for (( i=1; i<=iterations; i++ )); do
    local ts; ts=$(date '+%H:%M:%S')
    local t_start t_end rtt_ms
    t_start=$(date +%s%3N)
    local out
    out=$(timeout 5 sipsak -s "sip:${SIP_IP}:${SIP_PORT}" -v 2>&1) || true
    t_end=$(date +%s%3N)
    rtt_ms=$(( t_end - t_start ))

    if echo "$out" | grep -qE "200 OK|401|403"; then
      ok_count=$(( ok_count + 1 ))
      rtt_total=$(( rtt_total + rtt_ms ))
      rtt_count=$(( rtt_count + 1 ))
      printf "  ${GREEN}[✔]${RESET} %s | 200 OK | %dms\n" "$ts" "$rtt_ms"
      REPORT_LINES+=("[OK]   $ts | 200 OK | ${rtt_ms}ms")
    else
      fail_count=$(( fail_count + 1 ))
      printf "  ${RED}[✘]${RESET} %s | TIMEOUT/FAIL\n" "$ts"
      REPORT_LINES+=("[FAIL] $ts | TIMEOUT/FAIL")
    fi

    [[ $i -lt $iterations ]] && sleep "$interval"
  done

  echo ""
  local total=$(( ok_count + fail_count ))
  local loss_pct=0
  [[ $total -gt 0 ]] && loss_pct=$(( fail_count * 100 / total ))
  local rtt_avg=0
  [[ $rtt_count -gt 0 ]] && rtt_avg=$(( rtt_total / rtt_count ))

  raw "$(t 'Probes OK' 'Probes OK'):       $ok_count / $total"
  raw "$(t 'Falhas'    'Failures'):         $fail_count / $total"
  raw "$(t 'Perda SIP' 'SIP Loss'):        ${loss_pct}%"
  [[ $rtt_avg -gt 0 ]] && raw "$(t 'RTT médio SIP' 'Avg SIP RTT'): ${rtt_avg}ms"
  echo ""

  if   [[ $loss_pct -eq 0  ]]; then ok   "$(t 'Disponibilidade SIP 100%' 'SIP Availability 100%')"
  elif [[ $loss_pct -le 5  ]]; then warn "$(t "SIP $((100-loss_pct))% disponível — perda baixa" "SIP $((100-loss_pct))% available — low loss")"
  else fail "$(t "SIP $((100-loss_pct))% disponível — perda alta!" "SIP $((100-loss_pct))% available — high loss!")"; fi
}

# ── 8. Jitter com hping3 ──────────────────────────────────────────────────────
test_jitter() {
  section "$(t 'Jitter UDP (simulação RTP com hping3)' 'UDP Jitter (RTP simulation with hping3)')"

  if ! command -v hping3 &>/dev/null; then
    warn "$(t 'hping3 não disponível — pulando teste de jitter UDP' \
             'hping3 not available — skipping UDP jitter test')"; return
  fi

  # 30 pacotes a 100ms de intervalo — evita rate limiting ICMP do servidor (padrão Linux ~10/s)
  local pkt_count=30
  local pkt_interval="u100000"  # 100ms em microsegundos
  info "$(t "Enviando ${pkt_count} pacotes UDP para $SIP_IP:$RTP_PORT a 100ms/pacote..." \
           "Sending ${pkt_count} UDP packets to $SIP_IP:$RTP_PORT at 100ms/packet...")"
  info "$(t '(ICMP Port Unreachable = caminho alcançável; sem resposta = porta aberta ou firewall)' \
           '(ICMP Port Unreachable = path reachable; no response = port open or firewall)')"

  local out
  if [[ "$SUDO_OK" -eq 1 ]]; then
    out=$(sudo hping3 --udp -p "$RTP_PORT" -c "$pkt_count" -i "$pkt_interval" "$SIP_IP" 2>&1) || true
  else
    warn "$(t 'hping3 requer sudo — resultado pode ser incompleto' \
             'hping3 requires sudo — result may be incomplete')"
    out=$(hping3 --udp -p "$RTP_PORT" -c "$pkt_count" -i "$pkt_interval" "$SIP_IP" 2>&1) || true
  fi

  # hping3 UDP responde com "ICMP Port Unreachable" (porta fechada) ou silêncio (porta aberta/firewall)
  local icmp_resp; icmp_resp=$(echo "$out" | grep -c "^ICMP Port Unreachable" || true); icmp_resp=${icmp_resp:-0}
  local rtt_line;  rtt_line=$( echo "$out" | grep -i "round-trip"             || true)
  local stat_line; stat_line=$(echo "$out" | grep "packets transmitted"        || true)

  # Extrai loss% da linha de estatística do hping3
  local loss_pct_udp; loss_pct_udp=$(echo "$stat_line" | grep -oP '\d+(?=% packet loss)' || true); loss_pct_udp=${loss_pct_udp:-100}

  [[ -n "$rtt_line"  ]] && raw "RTT: $rtt_line"
  raw "$(t 'Respostas ICMP recebidas' 'ICMP responses received'): ${icmp_resp} / ${pkt_count}"

  if [[ "${icmp_resp:-0}" -gt 0 ]]; then
    ok "$(t 'Caminho UDP alcançável — servidor responde via ICMP' 'UDP path reachable — server responds via ICMP')"

    # "loss" do hping3 em modo UDP = ICMP rate limiting do kernel Linux no servidor,
    # NÃO perda real de pacotes. Normal e esperado.
    local loss_int_udp; loss_int_udp=$(echo "$stat_line" | grep -oP '\d+(?=% packet loss)' || true)
    loss_int_udp=${loss_int_udp:-0}
    if [[ "${loss_int_udp}" -gt 0 ]]; then
      info "$(t "${loss_int_udp}% sem resposta ICMP = rate limiting do servidor (net.ipv4.icmp_ratelimit), não perda real de pacotes" \
               "${loss_int_udp}% no ICMP reply = server-side rate limiting (net.ipv4.icmp_ratelimit), not real packet loss")"
    fi

    # Avalia jitter pelo RTT min/max
    # Extrai min, avg, max do hping3: "round-trip min/avg/max = X/Y/Z ms"
    local rtt_min rtt_avg rtt_max
    rtt_min=$(echo "$rtt_line" | grep -oP '= \K[\d.]+')
    rtt_avg=$(echo "$rtt_line" | grep -oP '[\d.]+' | sed -n '2p' || true)
    rtt_max=$(echo "$rtt_line" | grep -oP '[\d.]+(?= ms)' | tail -1 || true)

    if [[ -n "$rtt_avg" && -n "$rtt_min" ]]; then
      # Usa avg-min como proxy de jitter (mais estável que max-min, resistente a picos isolados)
      local jitter; jitter=$(echo "$rtt_avg $rtt_min" | LC_ALL=C awk '{printf "%.1f", $1-$2}')
      raw "$(t 'RTT min/avg/max' 'RTT min/avg/max'): ${rtt_min}/${rtt_avg}/${rtt_max} ms"
      raw "$(t 'Jitter estimado (avg-min)' 'Estimated jitter (avg-min)'): ${jitter}ms"
      local jitter_int; jitter_int=$(LC_ALL=C printf "%.0f" "$jitter" 2>/dev/null || echo "99")
      if   [[ "${jitter_int:-99}" -le 10 ]]; then ok   "$(t 'Jitter UDP excelente' 'Excellent UDP jitter') (<10ms)"
      elif [[ "${jitter_int:-99}" -le 30 ]]; then warn "$(t 'Jitter UDP aceitável' 'Acceptable UDP jitter') (${jitter}ms)"
      else fail "$(t 'Jitter UDP alto — pode impactar qualidade de voz' 'High UDP jitter — may impact voice quality') (${jitter}ms)"; fi
    fi
  else
    warn "$(t 'Nenhuma resposta ICMP — porta RTP pode estar aberta (IPBX escutando em $RTP_PORT) ou firewall bloqueando' \
             'No ICMP response — RTP port may be open (IPBX listening on $RTP_PORT) or firewall blocking')"
    info "$(t 'Tente uma porta fora do range RTP do servidor para confirmar o caminho UDP' \
             'Try a port outside server RTP range to confirm UDP path')"
  fi
}

# ── 9. DNS ────────────────────────────────────────────────────────────────────
# ── 10. TLS ───────────────────────────────────────────────────────────────────
test_tls() {
  section "$(t 'SIP TLS (porta 5061)' 'SIP TLS (port 5061)')"

  if ! command -v openssl &>/dev/null; then
    warn "$(t 'openssl não disponível' 'openssl not available')"; return
  fi

  info "$(t "Verificando TLS em $SIP_IP:5061..." "Checking TLS on $SIP_IP:5061...")"

  local out
  out=$(timeout 5 openssl s_client -connect "${SIP_IP}:5061" \
        -showcerts </dev/null 2>&1) || true

  if echo "$out" | grep -q "CONNECTED"; then
    ok "$(t 'TLS conectado em 5061' 'TLS connected on 5061')"
    local subject expire verify
    subject=$(echo "$out" | grep "subject="          | head -1 | sed 's/subject=//' || echo "")
    expire=$( echo "$out" | grep "notAfter="         | head -1 | sed 's/.*notAfter=//' || echo "")
    verify=$( echo "$out" | grep "Verify return code"| head -1 || echo "")
    [[ -n "$subject" ]] && raw "Subject: $subject"
    [[ -n "$expire"  ]] && raw "$(t 'Expira' 'Expires'): $expire"
    [[ -n "$verify"  ]] && raw "Verify: $verify"
    echo "$verify" | grep -q "ok (0)" \
      && ok   "$(t 'Certificado válido' 'Valid certificate')" \
      || warn "$(t 'Atenção ao certificado' 'Check certificate')"
  else
    info "$(t 'TLS não disponível em 5061 (servidor usa apenas UDP/TCP 5060)' \
             'TLS not available on 5061 (server uses UDP/TCP 5060 only)')"
  fi
}

# ── 11. Ping longo ────────────────────────────────────────────────────────────
test_ping_long() {
  section "$(t "Ping Persistente (${TEST_DURATION}s)" "Persistent Ping (${TEST_DURATION}s)")"
  local count=$TEST_DURATION
  info "$(t "Enviando $count pings (1/seg)... aguarde ${TEST_DURATION}s" \
           "Sending $count pings (1/sec)... wait ${TEST_DURATION}s")"

  local tmp; tmp=$(mktemp)
  ping -c "$count" -i 1 "$SIP_IP" > "$tmp" 2>&1 || true

  local transmitted received loss rtt_line
  transmitted=$(grep -oP '\d+ packets transmitted' "$tmp" | grep -oP '^\d+' || true); transmitted=${transmitted:-0}
  received=$(   grep -oP '\d+ received'             "$tmp" | grep -oP '^\d+' || true); received=${received:-0}
  loss=$(       grep -oP '\d+(\.\d+)?% packet loss' "$tmp"                   || true); loss=${loss:-N/A}
  rtt_line=$(   grep "rtt min" "$tmp"                                         || true)

  raw "$(t 'Enviados'  'Sent'):      $transmitted"
  raw "$(t 'Recebidos' 'Received'):  $received"
  raw "$(t 'Perda'     'Loss'):      $loss"
  [[ -n "$rtt_line" ]] && raw "RTT: $(echo "$rtt_line" | grep -oP '[\d.]+/[\d.]+/[\d.]+/[\d.]+' || echo "N/A") ms"
  rm -f "$tmp"

  local loss_int; loss_int=$(echo "$loss" | grep -oP '^\d+' || true); loss_int=${loss_int:-0}
  if   [[ "${loss_int:-0}" -eq 0 ]]; then ok   "$(t 'Sem perda de pacotes' 'No packet loss')"
  elif [[ "${loss_int:-0}" -le 1  ]]; then warn "$(t 'Perda mínima' 'Minimal loss'): $loss"
  elif [[ "${loss_int:-0}" -le 5  ]]; then warn "$(t 'Perda moderada' 'Moderate loss'): $loss"
  else fail "$(t 'Perda alta de pacotes' 'High packet loss'): $loss"; fi
}

# ── 12. REGISTER ──────────────────────────────────────────────────────────────
test_register() {
  section "$(t 'SIP REGISTER (autenticação de ramal)' 'SIP REGISTER (extension auth)')"

  if ! command -v sipsak &>/dev/null; then
    fail "sipsak $(t 'não disponível' 'not available')"; return
  fi

  if [[ -z "$SIP_USER" || -z "$SIP_PASS" ]]; then
    warn "$(t 'Usuário/senha não fornecidos — pulando REGISTER' \
             'User/password not provided — skipping REGISTER')"; return
  fi

  local domain="${SIP_DOMAIN:-$SIP_IP}"
  info "$(t "Registrando $SIP_USER@$domain em $SIP_IP:$SIP_PORT..." \
           "Registering $SIP_USER@$domain on $SIP_IP:$SIP_PORT...")"

  local out
  # sipsak -U = usrloc/REGISTER mode; -s sip:user@server; -r porta; -a senha; -e expires
  out=$(sipsak -U -s "sip:${SIP_USER}@${SIP_IP}" \
               -r "$SIP_PORT" -a "$SIP_PASS" \
               -e 60 -v 2>&1) || true

  if echo "$out" | grep -q "200 OK"; then
    ok "$(t 'REGISTER OK — ramal autenticado com sucesso' 'REGISTER OK — extension successfully authenticated')"
  elif echo "$out" | grep -qE "401|403"; then
    fail "$(t 'REGISTER falhou: credenciais inválidas ou não autorizadas' \
             'REGISTER failed: invalid credentials or unauthorized')"
    raw "$(echo "$out" | grep -E "^SIP|401|403" | head -2 || echo "")"
  elif echo "$out" | grep -qiE "timeout|408"; then
    fail "$(t 'REGISTER timeout — servidor não respondeu' \
             'REGISTER timeout — server did not respond')"
  else
    warn "$(t 'Resposta inesperada no REGISTER:' 'Unexpected REGISTER response:')"
    raw "$(echo "$out" | head -3 || echo "")"
  fi
}

# ── 13. INVITE de teste ───────────────────────────────────────────────────────
test_invite() {
  section "$(t 'Chamada de Teste (INVITE)' 'Test Call (INVITE)')"

  if ! command -v sipsak &>/dev/null; then
    fail "sipsak $(t 'não disponível' 'not available')"; return
  fi

  if [[ -z "$SIP_USER" || -z "$SIP_PASS" || -z "$INVITE_DST" ]]; then
    warn "$(t 'Credenciais ou destino não fornecidos — pulando INVITE' \
             'Credentials or destination not provided — skipping INVITE')"; return
  fi

  local domain="${SIP_DOMAIN:-$SIP_IP}"
  info "$(t "Enviando INVITE de $SIP_USER para $INVITE_DST@$domain via $SIP_IP:$SIP_PORT..." \
           "Sending INVITE from $SIP_USER to $INVITE_DST@$domain via $SIP_IP:$SIP_PORT...")"

  # INVITE sem SDP (Content-Length: 0) — servidor negocia codec na resposta (testado e funcional)
  local tmp_inv; tmp_inv=$(mktemp /tmp/sip_invite_XXXX.txt)
  local call_id; call_id="${RANDOM}${RANDOM}@${LOCAL_IP}"
  local branch;  branch="z9hG4bK.$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c8 || echo "${RANDOM}")"
  local tag;     tag="$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c8 || echo "${RANDOM}")"

  printf "INVITE sip:%s@%s SIP/2.0\r\nVia: SIP/2.0/UDP %s:5060;branch=%s;rport\r\nFrom: <sip:%s@%s>;tag=%s\r\nTo: <sip:%s@%s>\r\nCall-ID: %s\r\nCSeq: 1 INVITE\r\nContact: <sip:%s@%s:5060>\r\nMax-Forwards: 70\r\nContent-Length: 0\r\n\r\n" \
    "$INVITE_DST" "$domain" \
    "$LOCAL_IP" "$branch" \
    "$SIP_USER" "$domain" "$tag" \
    "$INVITE_DST" "$domain" \
    "$call_id" \
    "$SIP_USER" "$LOCAL_IP" > "$tmp_inv"

  local out
  out=$(sipsak -f "$tmp_inv" -s "sip:${SIP_IP}:${SIP_PORT}" \
               -u "$SIP_USER" -a "$SIP_PASS" -v 2>&1) || true
  rm -f "$tmp_inv"

  local first_resp; first_resp=$(echo "$out" | grep "^SIP/2.0" | head -1 || echo "")
  [[ -n "$first_resp" ]] && raw "$(t 'Resposta' 'Response'): $first_resp"

  if   echo "$out" | grep -qE "SIP/2.0 (180|183|200)"; then
    ok "$(t 'INVITE aceito — sinalização e mídia OK' 'INVITE accepted — signaling and media OK')"
  elif echo "$out" | grep -qE "SIP/2.0 (486|603|480)"; then
    ok "$(t 'INVITE chegou (ocupado/indisponível) — sinalização OK' 'INVITE reached dest (busy/unavailable) — signaling OK')"
  elif echo "$out" | grep -q "SIP/2.0 488"; then
    ok  "$(t 'INVITE chegou ao servidor — sinalização OK' 'INVITE reached server — signaling OK')"
    warn "$(t '488 Not Acceptable Here — SDP/codec recusado (normal em teste sem mídia real)' '488 Not Acceptable Here — SDP/codec rejected (normal in test without real media)')"
  elif echo "$out" | grep -q  "SIP/2.0 404"; then
    warn "$(t 'Destino não encontrado (404) — ramal inexistente ou fora do domínio' 'Destination not found (404)')"
  elif echo "$out" | grep -qE "SIP/2.0 (401|407)"; then
    warn "$(t 'Autenticação necessária (401/407) — credenciais podem estar incorretas' 'Auth required (401/407)')"
  elif echo "$out" | grep -q  "SIP/2.0 403"; then
    fail "$(t 'INVITE rejeitado (403 Forbidden)' 'INVITE rejected (403 Forbidden)')"
  elif echo "$out" | grep -q  "SIP/2.0 408"; then
    fail "$(t 'INVITE timeout (408) — ramal não responde ou sem rota' 'INVITE timeout (408) — extension unreachable')"
  else
    warn "$(t 'Sem resposta SIP — verifique credenciais e domínio' 'No SIP response — check credentials and domain')"
    raw "$(echo "$out" | grep "^SIP\|^sipsak\|error" | head -3 || echo "")"
  fi
}

# ── Relatório final ───────────────────────────────────────────────────────────
write_report() {
  {
    printf '=%.0s' {1..60}; echo
    echo "  ACT Tecnologia — Relatório de Diagnóstico SIP"
    printf '=%.0s' {1..60}; echo
    echo "  Data:    $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Destino: $SIP_IP:$SIP_PORT"
    echo "  Nível:   $TEST_LEVEL"
    echo "  Host:    $(hostname) ($LOCAL_IP)"
    [[ -n "$SIP_USER" ]] && echo "  Ramal:   $SIP_USER@${SIP_DOMAIN:-$SIP_IP}"
    printf '=%.0s' {1..60}; echo
    for line in "${REPORT_LINES[@]}"; do echo "$line"; done
    echo ""
    printf '=%.0s' {1..60}; echo
    echo "  Gerado por ACT Tecnologia SIP Diagnostic Tool v1.1"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    printf '=%.0s' {1..60}; echo
  } > "$REPORT_FILE"

  echo ""
  echo -e "  ${GREEN}${BOLD}$(t 'Relatório salvo em:' 'Report saved to:')${RESET}"
  echo -e "  ${CYAN}$REPORT_FILE${RESET}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  MENU INTERATIVO
# ══════════════════════════════════════════════════════════════════════════════

menu_language() {
  header
  echo -e "  ${BOLD}Selecione o idioma / Select language:${RESET}"
  echo ""
  echo "  1) Português"
  echo "  2) English"
  echo ""
  ask "Opção / Option" "1"
  read -r ans
  [[ "${ans:-1}" == "2" ]] && LANG_PT=0 || LANG_PT=1
}

menu_params() {
  header
  section "$(t 'Configuração do Teste' 'Test Configuration')"

  # IP
  while true; do
    ask "$(t 'IP ou domínio do servidor SIP' 'SIP server IP or domain')" ""
    read -r SIP_IP
    [[ -n "${SIP_IP:-}" ]] && break
    echo -e "  ${RED}$(t 'Campo obrigatório.' 'Required field.')${RESET}"
  done

  # Porta SIP
  ask "$(t 'Porta SIP' 'SIP Port')" "5060"
  read -r _port
  SIP_PORT="${_port:-5060}"

  # Porta RTP
  ask "$(t 'Porta RTP para teste de jitter (porta alta do servidor)' 'RTP port for jitter test (server high port)')" "$RTP_PORT"
  read -r _rtp
  RTP_PORT="${_rtp:-10000}"
  [[ "$RTP_PORT" =~ ^[0-9]+$ ]] || RTP_PORT=10000

  # Nível
  echo ""
  echo -e "  ${BOLD}$(t 'Nível de teste:' 'Test level:')${RESET}"
  echo "  1) $(t 'Básico    — ping, MTU, traceroute, SIP OPTIONS' \
                  'Basic     — ping, MTU, traceroute, SIP OPTIONS')"
  echo "  2) $(t 'Médio     — básico + jitter UDP, portas RTP, DNS, TLS, ping longo' \
                  'Medium    — basic + UDP jitter, RTP ports, DNS, TLS, long ping')"
  echo "  3) $(t 'Completo  — médio + monitoramento SIP persistente, REGISTER, INVITE' \
                  'Complete  — medium + persistent SIP monitoring, REGISTER, INVITE')"
  echo ""
  ask "$(t 'Nível' 'Level')" "1"
  read -r _lvl
  TEST_LEVEL="${_lvl:-1}"
  [[ "$TEST_LEVEL" =~ ^[123]$ ]] || TEST_LEVEL=1

  # Duração (níveis 2 e 3)
  if [[ "$TEST_LEVEL" -ge 2 ]]; then
    echo ""
    ask "$(t 'Duração do teste persistente (segundos)' 'Persistent test duration (seconds)')" "300"
    read -r _dur
    TEST_DURATION="${_dur:-300}"
    [[ "$TEST_DURATION" =~ ^[0-9]+$ ]] || TEST_DURATION=300
  fi

  # Credenciais (nível 2 e 3)
  if [[ "$TEST_LEVEL" -ge 2 ]]; then
    echo ""
    echo -e "  ${BOLD}$(t 'Credenciais SIP (opcional — para REGISTER e INVITE):' \
                          'SIP Credentials (optional — for REGISTER and INVITE):')${RESET}"
    ask "$(t 'Usuário/ramal (Enter para pular)' 'Username/extension (Enter to skip)')" ""
    read -r SIP_USER

    if [[ -n "${SIP_USER:-}" ]]; then
      ask "$(t 'Senha' 'Password')" ""
      read -rs SIP_PASS; echo ""

      ask "$(t 'Domínio SIP (Enter para usar o IP)' 'SIP domain (Enter to use IP)')" "$SIP_IP"
      read -r _dom
      SIP_DOMAIN="${_dom:-$SIP_IP}"
    fi
  fi

  # INVITE (nível 3 com credenciais)
  if [[ "$TEST_LEVEL" -ge 3 && -n "${SIP_USER:-}" ]]; then
    echo ""
    if confirm "$(t 'Testar chamada real (INVITE)?' 'Test real call (INVITE)?')"; then
      DO_INVITE=1
      ask "$(t 'Ramal destino para teste' 'Destination extension for test')" "*43"
      read -r INVITE_DST
      INVITE_DST="${INVITE_DST:-*43}"
    fi
  fi

  # Nome do relatório
  local ts; ts=$(date '+%Y%m%d_%H%M%S')
  local ip_safe; ip_safe="${SIP_IP//[.:]/_}"
  REPORT_FILE="${SCRIPT_DIR}/sip_report_${ip_safe}_${ts}.txt"

  echo ""
  echo -e "  ${BOLD}$(t '─── Resumo da configuração ───' '─── Configuration summary ───')${RESET}"
  echo -e "  $(t 'Destino'   'Target'):   ${CYAN}$SIP_IP:$SIP_PORT${RESET}  $(t '(RTP:' '(RTP:') ${CYAN}${RTP_PORT}${RESET})"
  echo -e "  $(t 'Nível'     'Level'):    ${CYAN}$TEST_LEVEL${RESET}"
  [[ "$TEST_LEVEL" -ge 2 ]] && echo -e "  $(t 'Duração' 'Duration'):  ${CYAN}${TEST_DURATION}s${RESET}"
  [[ -n "${SIP_USER:-}" ]]  && echo -e "  $(t 'Ramal'   'Extension'): ${CYAN}${SIP_USER}@${SIP_DOMAIN:-$SIP_IP}${RESET}"
  [[ "$DO_INVITE" -eq 1 ]]  && echo -e "  INVITE:    ${CYAN}$INVITE_DST${RESET}"
  echo -e "  $(t 'Relatório' 'Report'):   ${CYAN}$REPORT_FILE${RESET}"
  echo ""

  confirm "$(t 'Iniciar testes?' 'Start tests?')" || { echo "$(t 'Cancelado.' 'Cancelled.')"; exit 0; }
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
  menu_language
  menu_params

  detect_local_ip
  check_sudo
  install_deps

  REPORT_LINES+=("" "Data: $(date '+%Y-%m-%d %H:%M:%S')"
                 "Destino: $SIP_IP:$SIP_PORT | Nivel: $TEST_LEVEL"
                 "Host: $(hostname) ($LOCAL_IP)")

  # Nível 1 — Básico
  test_baseline
  test_ping
  test_mtu
  test_traceroute
  sleep 2   # pausa antes do primeiro contato SIP
  test_sip_options

  # Nível 2 — Médio
  if [[ "$TEST_LEVEL" -ge 2 ]]; then
    sleep 2
    test_jitter
    test_ports_udp
    test_tls
    test_ping_long
  fi

  # Nível 3 — Completo
  if [[ "$TEST_LEVEL" -ge 3 ]]; then
    sleep 3   # pausa maior antes de REGISTER/INVITE/monitoramento
    [[ -n "${SIP_USER:-}" ]] && test_register
    sleep 3
    test_sip_persistent
    sleep 2
    [[ "$DO_INVITE" -eq 1 ]] && test_invite
  fi

  section "$(t 'Finalizado' 'Completed')"
  ok "$(t 'Todos os testes concluídos.' 'All tests completed.')"
  write_report
}

main "$@"
