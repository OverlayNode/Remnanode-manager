#!/usr/bin/env bash
# RemnaNode Manager — модуль: мониторинг: live-монитор, ресурсы, порты, логи, диагностика.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="4.1.0"

live_monitor() {
  local key=""
  while true; do
    clear || true
    print_header
    echo -e "${C_BOLD}Топ процессов по CPU${C_RESET}"
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 6
    echo
    if docker_available; then
      echo -e "${C_BOLD}Контейнеры${C_RESET}"
      docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}' 2>/dev/null || true
      echo
    fi
    echo -e "${C_BOLD}Подключения${C_RESET}"
    connection_summary
    echo
    echo -e "${C_GRAY}Обновление каждые 3 с. q — выход.${C_RESET}"
    if read -r -s -n 1 -t 3 key; then
      [[ "$key" == "q" || "$key" == "Q" || "$key" == "0" ]] && break
    fi
  done
}

connection_summary() {
  load_state 2>/dev/null || true
  local port label
  local -a ports=()
  [[ "$RAW_ENABLED" == "1" ]] && ports+=("tcp:${RAW_PORT}:VLESS RAW")
  [[ "$XHTTP_ENABLED" == "1" ]] && ports+=("tcp:${XHTTP_PORT}:VLESS XHTTP")
  [[ "$HY2_ENABLED" == "1" ]] && ports+=("udp:${HY2_PORT}:Hysteria2")
  ports+=("tcp:${NODE_PORT}:Node API")

  local entry proto established unique
  for entry in "${ports[@]}"; do
    proto="${entry%%:*}"
    port="${entry#*:}"; port="${port%%:*}"
    label="${entry##*:}"
    if [[ "$proto" == "tcp" ]]; then
      established="$(ss -H -tn state established "( sport = :${port} )" 2>/dev/null | wc -l)"
      unique="$(ss -H -tn state established "( sport = :${port} )" 2>/dev/null \
        | awk '{print $4}' | sed -E 's/:[0-9]+$//' | sort -u | grep -c . || true)"
      printf '  %-12s %5s/tcp  соединений: %-6s уникальных IP: %s\n' "$label" "$port" "$established" "$unique"
    else
      printf '  %-12s %5s/udp  (UDP без состояния — см. docker stats)\n' "$label" "$port"
    fi
  done
  printf '  %-12s всего TCP established: %s\n' "Сервер" "$(ss -H -tn state established 2>/dev/null | wc -l)"
}

server_details() {
  echo -e "${C_BOLD}Сервер${C_RESET}"
  echo "Hostname:  $(hostname)"
  echo "ОС:        $(. /etc/os-release && echo "${PRETTY_NAME}")"
  echo "Ядро:      $(uname -r) ($(uname -m))"
  echo "CPU:       $(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo) × $(nproc)"
  echo "Load:      $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "RAM:       $(memory_summary)"
  echo "Swap:      $(swap_summary)"
  echo "Uptime:    $(uptime_human)"
  echo "TCP CC:    $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / qdisc $(sysctl -n net.core.default_qdisc 2>/dev/null)"
  echo "Время:     $(date '+%F %T %Z') (NTP: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?'))"
  echo
  echo -e "${C_BOLD}Диски${C_RESET}"
  df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null || df -h
  echo
  echo -e "${C_BOLD}Сеть${C_RESET}"
  ip -brief address 2>/dev/null || true
  echo
  echo "Трафик с момента загрузки:"
  local name rx tx
  while read -r name rx tx; do
    printf '  %-12s RX %-10s TX %s\n' "$name" "$(human_bytes "$rx")" "$(human_bytes "$tx")"
  done < <(awk 'NR > 2 {gsub(/:/, " "); if ($1 != "lo") print $1, $2, $10}' /proc/net/dev)
  echo
  echo -e "${C_BOLD}Топ процессов по памяти${C_RESET}"
  ps -eo pid,comm,%mem,rss --sort=-%mem 2>/dev/null | head -n 8
}

docker_overview() {
  docker_available || die "Docker недоступен."
  echo -e "${C_BOLD}Контейнеры${C_RESET}"
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  echo
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'
  echo
  echo -e "${C_BOLD}Использование диска Docker${C_RESET}"
  docker system df
}

ports_overview() {
  echo -e "${C_BOLD}Слушающие порты${C_RESET}"
  ss -Hlntup 2>/dev/null | awk '{printf "  %-5s %-28s %s\n", $1, $5, $7}' | sort -u
  echo
  echo -e "${C_BOLD}Нагрузка по inbound'ам${C_RESET}"
  connection_summary
  echo
  echo -e "${C_BOLD}Топ-10 IP по числу соединений${C_RESET}"
  ss -H -tn state established 2>/dev/null | awk '{print $4}' | sed -E 's/:[0-9]+$//; s/^\[|\]$//g' \
    | sort | uniq -c | sort -rn | head -n 10
}

network_speed_test() {
  info "Скачиваю 100 MB с speed.cloudflare.com..."
  local result
  result="$(curl -o /dev/null -s -w '%{speed_download} %{time_total}' --max-time 60 \
    'https://speed.cloudflare.com/__down?bytes=100000000' || true)"
  if [[ -z "$result" ]]; then
    warn "Тест не удался."
    return 0
  fi
  awk '{printf "Download: %.1f Mbit/s (%.1f s)\n", $1 * 8 / 1000000, $2}' <<<"$result"
  info "Задержка до 1.1.1.1:"
  ping -c 4 -q 1.1.1.1 2>/dev/null | tail -n 1 || true
}

logs_menu() {
  while true; do
    clear || true
    echo -e "${C_BOLD}Логи${C_RESET}"
    echo
    echo "1. RemnaNode (последние 200)"
    echo "2. RemnaNode — в реальном времени"
    echo "3. nginx-selfsteal"
    echo "4. Журнал manager (${INSTALL_LOG})"
    echo "5. Системный журнал (ошибки за 24 ч)"
    echo "6. UFW (заблокированные подключения)"
    echo "7. WARP watchdog / Psiphon / Tor"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) docker logs --tail 200 remnanode 2>&1 | less -R +G || true ;;
      2) echo "Ctrl+C — выход"; docker logs -f --tail 50 remnanode 2>&1 || true ;;
      3) docker logs --tail 200 nginx-selfsteal 2>&1 | less -R +G || true ;;
      4) less -R +G "$INSTALL_LOG" || true ;;
      5) journalctl -p err --since "24 hours ago" --no-pager 2>/dev/null | tail -n 200 | less -R +G || true ;;
      6) journalctl -k --since "24 hours ago" --no-pager 2>/dev/null | grep -F 'UFW BLOCK' | tail -n 200 | less -R +G || true ;;
      7)
        journalctl -u warp-watchdog -u wg-quick@warp -u vps-psiphon -u tor --since "24 hours ago" --no-pager 2>/dev/null \
          | tail -n 200 | less -R +G || true
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

monitoring_menu() {
  while true; do
    clear || true
    print_header
    echo -e "${C_BOLD}Мониторинг${C_RESET}"
    echo
    echo "1. Live-монитор"
    echo "2. Сервер подробно (CPU, RAM, диски, сеть, трафик)"
    echo "3. Docker: контейнеры и ресурсы"
    echo "4. Порты и подключения"
    echo "5. Логи"
    echo "6. Диагностика Node / Selfsteal"
    echo "7. Тест скорости сети"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) live_monitor ;;
      2) run_action server_details; pause ;;
      3) run_action docker_overview; pause ;;
      4) run_action ports_overview; pause ;;
      5) logs_menu ;;
      6) run_action diagnostics; pause ;;
      7) run_action network_speed_test; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

show_remote_certificate() {
  local port="$1"

  echo | timeout 10 openssl s_client \
    -connect "${DOMAIN}:${port}" \
    -servername "$DOMAIN" \
    -showcerts 2>/dev/null \
    | openssl x509 \
      -noout \
      -subject \
      -issuer \
      -dates \
      -ext subjectAltName 2>/dev/null
}

diagnostics() {
  load_state
  load_reality

  echo
  echo -e "${C_BOLD}=== Remnawave Node diagnostics ===${C_RESET}"
  echo "Manager: ${SCRIPT_VERSION}"
  echo "Mode: ${INSTALL_MODE:-unknown}"
  echo "Node: $(node_state) · $(node_version) · Xray $(xray_version)"
  echo

  if command -v docker >/dev/null 2>&1; then
    ok "Docker: $(docker --version)"
    docker compose version || true
  else
    err "Docker не установлен."
  fi

  echo
  echo "--- Containers ---"
  if [[ -f "$NODE_COMPOSE_FILE" ]]; then
    manager_compose ps || true
  else
    warn "Compose-файл Node отсутствует: ${NODE_COMPOSE_FILE}"
  fi

  echo
  echo "--- Firewall ---"
  ufw status verbose || true

  echo
  echo "--- Listening sockets ---"
  ss -lntup | grep -E "(:22 |:${NODE_PORT} |:${RAW_PORT:-0} |:${XHTTP_PORT:-0} |:${HY2_PORT:-0} )" || true

  echo
  echo "--- Routing / geo ---"
  echo "GEO_ENABLED=${GEO_ENABLED} RU_POLICY=${RU_POLICY} BLOCK_ADS=${BLOCK_ADS}"
  if geo_files_present; then
    ls -la "${GEO_DIR}/${GEO_SITE_FILE}" "${GEO_DIR}/${GEO_IP_FILE}"
    docker exec remnanode ls -la "${XRAY_ASSET_DIR}/" 2>/dev/null || true
  fi
  echo "WARP=${WARP_OUTBOUND} PSIPHON=${PSIPHON_OUTBOUND} TOR=${TOR_OUTBOUND}"
  [[ "$WARP_OUTBOUND" == "1" ]] && { ip -brief address show warp 2>/dev/null || warn "Интерфейс warp не найден."; }
  [[ "$TOR_OUTBOUND" == "1" ]] && { ss -Hlnt '( sport = :9050 )' | grep -q . && ok "Tor SOCKS 9050 слушает." || warn "Tor SOCKS 9050 не слушает."; }
  [[ "$PSIPHON_OUTBOUND" == "1" ]] && { ss -Hlnt "( sport = :${PSIPHON_PORT} )" | grep -q . && ok "Psiphon SOCKS ${PSIPHON_PORT} слушает." || warn "Psiphon SOCKS ${PSIPHON_PORT} не слушает."; }

  if is_selfsteal_mode; then
    echo
    echo "--- DNS ---"
    dig +short A "$DOMAIN" || true
    dig +short AAAA "$DOMAIN" || true

    echo
    echo "--- Local certificate ---"
    if [[ -f "${BASE_DIR}/ssl/fullchain.pem" ]]; then
      openssl x509 \
        -in "${BASE_DIR}/ssl/fullchain.pem" \
        -noout -subject -issuer -dates -ext subjectAltName || true
    else
      err "Нет ${BASE_DIR}/ssl/fullchain.pem"
    fi

    echo
    echo "--- Nginx / socket ---"
    if docker inspect nginx-selfsteal >/dev/null 2>&1; then
      docker exec nginx-selfsteal nginx -t || true
    else
      err "nginx-selfsteal не существует."
    fi

    ls -lah /dev/shm/nginx.sock 2>/dev/null || true
    docker exec remnanode ls -lah /dev/shm/nginx.sock 2>/dev/null || true

    if [[ "$RAW_ENABLED" == "1" ]]; then
      echo
      echo "--- Remote TLS via RAW Reality fallback :${RAW_PORT} ---"
      show_remote_certificate "$RAW_PORT" || warn "Сертификат через RAW port не получен."
    fi

    if [[ "$XHTTP_ENABLED" == "1" ]]; then
      echo
      echo "--- Remote TLS via XHTTP Reality fallback :${XHTTP_PORT} ---"
      show_remote_certificate "$XHTTP_PORT" || warn "Сертификат через XHTTP port не получен."
    fi

    echo
    echo "--- acme.sh ---"
    if [[ -x "$ACME_BIN" ]]; then
      "$ACME_BIN" --info -d "$DOMAIN" --ecc 2>/dev/null || true
    else
      warn "acme.sh не найден."
    fi
  fi

  echo
  echo "--- Generated profile ---"
  if [[ -f "$PROFILE_FILE" ]]; then
    jq empty "$PROFILE_FILE" && ok "JSON profile syntax OK." || err "JSON profile invalid."
    validate_generated_profile || true
  else
    warn "Profile ещё не создан."
  fi

  echo
  echo "--- Recent RemnaNode log ---"
  docker logs --tail 40 remnanode 2>&1 || true

  if docker inspect nginx-selfsteal >/dev/null 2>&1; then
    echo
    echo "--- Recent nginx-selfsteal log ---"
    docker logs --tail 40 nginx-selfsteal 2>&1 || true
  fi

  echo
}

# Пошаговая проверка Hysteria2 на ноде: где именно обрывается цепочка.
hy2_diagnose() {
  load_state
  local problems=0 port="$HY2_PORT" cert="${BASE_DIR}/ssl/fullchain.pem" line

  echo -e "${C_BOLD}Проверка Hysteria2${C_RESET} (UDP ${port}, SNI ${DOMAIN:-—})"
  echo

  if [[ "$HY2_ENABLED" != "1" ]]; then
    err "Hysteria2 не выбран в inbound'ах этой ноды (меню «Xray profile» → «Настроить inbound'ы заново»)."
    return 1
  fi

  # 1. Профиль.
  if [[ -f "$PROFILE_FILE" ]] && jq -e '.inbounds[] | select(.tag == "HYSTERIA2")' "$PROFILE_FILE" >/dev/null 2>&1; then
    ok "1. Inbound HYSTERIA2 есть в сгенерированном профиле."
  else
    err "1. В ${PROFILE_FILE} нет inbound'а HYSTERIA2 — пересобери профиль."
    problems=$((problems + 1))
  fi

  # 2. Xray на ноде реально слушает UDP-порт — значит, Panel прислала профиль с inbound'ом.
  line="$(ss -Hlnup "( sport = :${port} )" 2>/dev/null | head -n1)"
  if [[ "$line" == *xray* || "$line" == *rw-core* ]]; then
    ok "2. Xray слушает UDP ${port}."
  elif [[ -n "$line" ]]; then
    err "2. UDP ${port} занят другим процессом: ${line}"
    problems=$((problems + 1))
  else
    err "2. Никто не слушает UDP ${port}. Профиль с HYSTERIA2 не применён к ноде в Panel,"
    err "   либо Xray не смог поднять inbound (см. пункт 6)."
    problems=$((problems + 1))
  fi

  # 3. Firewall.
  if ! command -v ufw >/dev/null 2>&1 || ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "3. UFW не активен — проверь только firewall провайдера."
  elif ufw status 2>/dev/null | grep -Eq "^${port}/udp[[:space:]]+ALLOW|^${port}[[:space:]]+ALLOW"; then
    ok "3. UFW разрешает ${port}/udp."
  else
    err "3. UFW не пропускает ${port}/udp. Исправить: ufw allow ${port}/udp"
    problems=$((problems + 1))
  fi
  warn "   Firewall/security group провайдера тоже должен пропускать ${port}/UDP — из скрипта это не проверить."

  # 4. Сертификат.
  if [[ ! -r "$cert" ]]; then
    err "4. Нет сертификата ${cert}."
    problems=$((problems + 1))
  else
    local days san
    days="$(cert_days_left 2>/dev/null || echo -1)"
    san="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS://p' | tr '\n' ' ')"
    if ((days < 0)); then
      err "4. Сертификат истёк — продли в меню «Домен и SSL»."
      problems=$((problems + 1))
    elif [[ " ${san} " != *" ${DOMAIN} "* ]]; then
      err "4. Сертификат выписан на «${san}», а не на ${DOMAIN}."
      problems=$((problems + 1))
    else
      ok "4. Сертификат для ${DOMAIN}, осталось ${days} дн."
    fi
  fi

  # 5. Контейнер видит ключ и сертификат по пути из профиля.
  if ! node_running; then
    err "5–6. Контейнер remnanode не запущен — проверить доступ к сертификату и логи нельзя."
    problems=$((problems + 1))
  elif docker exec remnanode test -r /opt/remnanode/ssl/privkey.pem 2>/dev/null \
    && docker exec remnanode test -r /opt/remnanode/ssl/fullchain.pem 2>/dev/null; then
    ok "5. Контейнер remnanode читает /opt/remnanode/ssl/*.pem."
  else
    err "5. Контейнер remnanode не видит /opt/remnanode/ssl — нужен volume /opt/remnanode/ssl:/opt/remnanode/ssl:ro."
    problems=$((problems + 1))
  fi

  # 6. Ошибки Xray про hysteria/QUIC/TLS.
  local log_errors=""
  if node_running; then
    log_errors="$(docker logs --since 24h remnanode 2>&1 | grep -iE 'hysteria|quic|certificate|tls:' | grep -iE 'fail|error|invalid|denied' | tail -n 5 || true)"
  fi
  if ! node_running; then
    :
  elif [[ -n "$log_errors" ]]; then
    err "6. В логах ноды есть ошибки:"
    printf '%s\n' "$log_errors" | sed 's/^/   /'
    problems=$((problems + 1))
  else
    ok "6. Ошибок hysteria/QUIC/TLS в логах ноды за сутки нет."
  fi

  # 7. Профиль в Panel (если есть API-токен).
  if panel_configured && [[ -n "$PANEL_PROFILE_UUID" ]]; then
    local remote
    remote="$( (panel_request GET "/api/config-profiles/${PANEL_PROFILE_UUID}") 2>/dev/null || true)"
    if jq -e '.response.config.inbounds[] | select(.protocol == "hysteria")' <<<"$remote" >/dev/null 2>&1; then
      ok "7. В Config Profile панели есть inbound hysteria."
      if [[ -n "$HY2_OBFS_PASSWORD" ]] && ! jq -e --arg p "$HY2_OBFS_PASSWORD" \
        '.response.config.inbounds[] | select(.protocol == "hysteria") | .streamSettings.finalmask.udp[]? | select(.settings.password == $p)' \
        <<<"$remote" >/dev/null 2>&1; then
        err "   В панели другой пароль Salamander или его нет — отправь профиль заново."
        problems=$((problems + 1))
      fi
    else
      err "7. В Config Profile панели нет inbound'а hysteria — отправь профиль (меню «Remnawave Panel API»)."
      problems=$((problems + 1))
    fi
  else
    warn "7. Panel API не настроен — проверь вручную, что профиль с HYSTERIA2 назначен ноде."
  fi

  echo
  echo "Что проверить в Panel и у клиента:"
  echo "  • Hosts: есть хост для inbound'а HYSTERIA2, адрес ${DOMAIN}, порт ${port}, SNI ${DOMAIN};"
  if [[ -n "$HY2_OBFS_PASSWORD" ]]; then
    echo "  • у этого хоста в Final mask: $(hy2_host_finalmask_json)"
    echo "    (без него ссылка hysteria2:// будет без obfs, и клиент не подключится);"
  else
    echo "  • при подключении из РФ QUIC на UDP ${port} часто режется ТСПУ — включи Salamander;"
  fi
  echo "  • inbound HYSTERIA2 включён в Internal Squad пользователя;"
  echo "  • клиент поддерживает Hysteria2 (Happ, v2rayN, Hiddify, NekoBox; ядро Xray ≥ 26 или sing-box)."
  echo
  if ((problems == 0)); then
    ok "На стороне ноды проблем не найдено."
  else
    warn "Найдено проблем на ноде: ${problems}."
  fi
}

# Включает/выключает Salamander без повторного выбора протоколов.
hy2_toggle_obfs() {
  load_state
  [[ "$HY2_ENABLED" == "1" ]] || die "Hysteria2 не включён."
  if [[ -n "$HY2_OBFS_PASSWORD" ]]; then
    confirm_no_default "Выключить Salamander? Клиентам со старой ссылкой нужно обновить подписку." || return 0
    HY2_OBFS_PASSWORD=""
  else
    HY2_OBFS_PASSWORD="$(openssl rand -hex 16)"
  fi
  save_state
  generate_xray_profile 1
  echo
  if [[ -n "$HY2_OBFS_PASSWORD" ]]; then
    ok "Salamander включён. Вставь в Panel → Hosts → хост HYSTERIA2 → Final mask:"
    echo "  $(hy2_host_finalmask_json)"
  else
    ok "Salamander выключен. Очисти поле Final mask у хоста HYSTERIA2 в Panel."
  fi
  warn "Отправь обновлённый профиль в Panel."
}
