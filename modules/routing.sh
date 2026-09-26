#!/usr/bin/env bash
# RemnaNode Manager — модуль: routing: geo-файлы roscomvpn, DNS, политика РФ-трафика, клиентская маршрутизация.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="4.2.0"

show_client_routing() {
  load_state
  generate_client_routing
  echo -e "${C_BOLD}Клиентская маршрутизация${C_RESET}: РФ + белые списки → напрямую, торренты → блок, остальное → прокси."
  echo
  echo "Чтобы РФ-сайты и приложения не видели VPN, нужны все три пункта:"
  echo "  • РФ-трафик идёт с клиента напрямую (с домашнего IP), а не через ноду;"
  echo "  • РФ-домены резолвятся РФ-DNS напрямую, остальные — DoH через туннель (нет утечки DNS);"
  echo "  • РФ-приложения исключены из VPN целиком (раздельное туннелирование) —"
  echo "    иначе на Android/iOS они видят VPN-интерфейс, независимо от маршрутизации."
  echo
  echo "1) Happ: профиль маршрутизации по ссылке (или вставить в Remnawave → Subscription → Happ routing):"
  echo
  printf 'happ://routing/onadd/%s\n' "$(base64 -w0 < "$CLIENT_ROUTING_FILE")"
  echo
  echo "   JSON: ${CLIENT_ROUTING_FILE}"
  echo
  echo "2) Xray JSON-шаблон подписки Remnawave (теги proxy/direct/block):"
  echo "   routing.rules: ${CLIENT_RULES_FILE}"
  echo "   dns:           ${CLIENT_DNS_FILE}"
  echo
  jq -c '.[]' "$CLIENT_RULES_FILE"
  echo
  echo "3) Приложения для исключения из VPN: ${CLIENT_APPS_FILE}"
  grep -v '^#' "$CLIENT_APPS_FILE" | paste -sd' ' - | fold -s -w 100 | sed 's/^/   /'
}

# Выбор РФ-резолверов для РФ-доменов.
set_dns_ru() {
  load_state
  echo "DNS для РФ-доменов (сейчас: ${DNS_RU})"
  echo "1. Яндекс: 77.88.8.8, 77.88.8.1"
  echo "2. Яндекс DoH: https://77.88.8.8/dns-query, https://77.88.8.1/dns-query"
  echo "3. Свой список (через запятую: IP, https://…, tcp://…)"
  local choice value
  read -r -p "Выбор [1]: " choice
  case "${choice:-1}" in
    1) value="77.88.8.8,77.88.8.1" ;;
    2) value="https://77.88.8.8/dns-query,https://77.88.8.1/dns-query" ;;
    3) read -r -p "Список: " value ;;
    *) die "Некорректный выбор." ;;
  esac
  value="${value// /}"
  validate_dns_list "$value" || die "Некорректный список DNS: ${value}"
  DNS_RU="$value"
  save_state
  generate_xray_profile 1
}

# Выбор зарубежных резолверов для всех остальных доменов.
set_dns_foreign() {
  load_state
  echo "DNS для остальных доменов (сейчас: ${DNS_FOREIGN})"
  echo "1. Cloudflare + Google DoH"
  echo "2. Cloudflare DoH"
  echo "3. Google DoH"
  echo "4. Quad9 DoH"
  echo "5. Свой список (через запятую)"
  local choice value
  read -r -p "Выбор [1]: " choice
  case "${choice:-1}" in
    1) value="https://1.1.1.1/dns-query,https://8.8.8.8/dns-query" ;;
    2) value="https://1.1.1.1/dns-query,https://1.0.0.1/dns-query" ;;
    3) value="https://8.8.8.8/dns-query,https://8.8.4.4/dns-query" ;;
    4) value="https://9.9.9.9/dns-query,https://149.112.112.112/dns-query" ;;
    5) read -r -p "Список: " value ;;
    *) die "Некорректный выбор." ;;
  esac
  value="${value// /}"
  validate_dns_list "$value" || die "Некорректный список DNS: ${value}"
  DNS_FOREIGN="$value"
  save_state
  generate_xray_profile 1
}

toggle_dns_hijack() {
  load_state
  if [[ "$DNS_HIJACK" == "1" ]]; then
    warn "Без перехвата DNS-запросы клиентов на порт 53 уходят к тем резолверам, которые они указали."
    confirm_no_default "Отключить перехват клиентского DNS?" || return 0
    DNS_HIJACK="0"
  else
    DNS_HIJACK="1"
  fi
  save_state
  ok "Перехват клиентского DNS: $([[ "$DNS_HIJACK" == 1 ]] && echo включён || echo выключен)"
  generate_xray_profile 1
}

dns_menu() {
  while true; do
    clear || true
    load_state
    echo -e "${C_BOLD}DNS${C_RESET}"
    echo
    echo "РФ-домены:        ${DNS_RU}  (ответ принимается, только если указывает на РФ-адрес)"
    echo "Остальные домены: ${DNS_FOREIGN}"
    echo "Перехват клиентского DNS (порт 53) на ноде: $([[ "$DNS_HIJACK" == 1 ]] && echo включён || echo выключен)"
    echo
    echo "1. DNS для РФ-доменов"
    echo "2. DNS для остальных доменов"
    echo "3. Перехват клиентского DNS: вкл/выкл"
    echo "4. Проверить резолв с ноды"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action set_dns_ru; pause ;;
      2) run_action set_dns_foreign; pause ;;
      3) run_action toggle_dns_hijack; pause ;;
      4) run_action dns_check; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

# Резолвит пару доменов через выбранные серверы — проверка доступности.
dns_check() {
  load_state
  local server ru_server
  ru_server="$(client_domestic_dns_ip)"
  command -v dig >/dev/null 2>&1 || die "Нужен dig (dnsutils)."
  echo "РФ-DNS ${ru_server}: ya.ru → $(dig +short +time=3 +tries=1 A ya.ru @"$ru_server" | head -n1 || true)"
  server="$(client_remote_doh)"
  echo "DoH ${server}: example.com → $(curl -fsS --max-time 5 -H 'accept: application/dns-json' "${server}?name=example.com&type=A" 2>/dev/null \
    | jq -r '[.Answer[]?.data] | first // "нет ответа"' 2>/dev/null || echo 'нет ответа')"
}

# Скачивает geo-файлы. Замена содержимого выполняется на месте (cat >), чтобы
# не менялся inode — иначе bind mount в контейнере продолжит видеть старый файл.
# Печатает 1, если файлы изменились.
geo_download() {
  mkdir -p "$GEO_DIR"
  chmod 755 "$GEO_DIR"
  local changed=0 pair url file tmp size
  for pair in "${GEO_SITE_URL}|${GEO_SITE_FILE}" "${GEO_IP_URL}|${GEO_IP_FILE}"; do
    url="${pair%%|*}"
    file="${GEO_DIR}/${pair#*|}"
    tmp="$(mktemp "${GEO_DIR}/.download.XXXXXX")"
    if ! curl --proto '=https' -fsSL --max-time 180 "$url" -o "$tmp"; then
      rm -f "$tmp"
      err "Не удалось скачать ${url}"
      return 1
    fi
    size="$(stat -c %s "$tmp")"
    if ((size < 10240)); then
      rm -f "$tmp"
      err "Файл ${url} подозрительно мал (${size} байт)."
      return 1
    fi
    if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
      rm -f "$tmp"
    else
      cat "$tmp" > "$file"
      rm -f "$tmp"
      chmod 644 "$file"
      changed=1
    fi
  done
  printf '%s' "$changed"
}

write_geo_updater() {
  cat > "$GEO_UPDATER" <<EOF
#!/usr/bin/env bash
# RemnaNode Manager: ежедневное обновление roscomvpn geosite/geoip.
set -euo pipefail
dir='${GEO_DIR}'
changed=0
for pair in '${GEO_SITE_URL}|${GEO_SITE_FILE}' '${GEO_IP_URL}|${GEO_IP_FILE}'; do
  url="\${pair%%|*}"
  file="\${dir}/\${pair#*|}"
  tmp="\$(mktemp "\${dir}/.download.XXXXXX")"
  if ! curl --proto '=https' -fsSL --max-time 180 "\$url" -o "\$tmp"; then
    rm -f "\$tmp"; echo "download failed: \$url" >&2; exit 1
  fi
  if (( \$(stat -c %s "\$tmp") < 10240 )); then
    rm -f "\$tmp"; echo "file too small: \$url" >&2; exit 1
  fi
  if [[ -f "\$file" ]] && cmp -s "\$tmp" "\$file"; then
    rm -f "\$tmp"
  else
    cat "\$tmp" > "\$file"; rm -f "\$tmp"; changed=1
  fi
done
if (( changed )) && docker inspect remnanode >/dev/null 2>&1; then
  # Xray читает geo-файлы при старте.
  docker restart remnanode >/dev/null
  echo "geo files updated, remnanode restarted"
fi
EOF
  chmod 755 "$GEO_UPDATER"

  cat > /etc/systemd/system/remnanode-geo-update.service <<EOF
[Unit]
Description=RemnaNode Manager: update roscomvpn geo files
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${GEO_UPDATER}
EOF

  cat > /etc/systemd/system/remnanode-geo-update.timer <<'EOF'
[Unit]
Description=RemnaNode Manager: daily geo files update

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now remnanode-geo-update.timer >/dev/null
}

geo_enable() {
  require_compose
  info "Скачиваю roscomvpn geosite/geoip..."
  geo_download >/dev/null || die "Geo-файлы не скачаны."
  compose_edit geo-add "$GEO_DIR"
  manager_compose up -d --remove-orphans
  write_geo_updater

  node_wait_healthy || true
  if docker exec remnanode test -s "${XRAY_ASSET_DIR}/${GEO_SITE_FILE}" 2>/dev/null; then
    ok "Geo-файлы смонтированы в ${XRAY_ASSET_DIR}/ контейнера."
  else
    warn "Не удалось проверить geo-файлы внутри контейнера."
  fi

  GEO_ENABLED="1"
  save_state
  generate_xray_profile 1
  warn "Профиль ссылается на ext:${GEO_SITE_FILE}. Включи geo на ВСЕХ нодах с этим Config Profile, иначе Xray на них не запустится."
  if panel_configured && confirm "Отправить обновлённый профиль в Panel сейчас?"; then
    load_module panel
    panel_push_profile
  fi
}

geo_update_now() {
  load_state
  local changed
  changed="$(geo_download)" || die "Обновление не удалось."
  if [[ "$changed" == "1" ]]; then
    ok "Geo-файлы обновлены."
    if node_running && confirm "Перезапустить Node, чтобы Xray перечитал geo-файлы?"; then
      docker restart remnanode >/dev/null
    fi
  else
    ok "Geo-файлы уже актуальны."
  fi
}

geo_disable() {
  require_compose
  warn "Сначала обнови профиль в Panel без ext:-правил, иначе Xray не запустится после удаления файлов."
  confirm_no_default "Отключить roscomvpn geo на этой ноде?" || return 0
  GEO_ENABLED="0"
  save_state
  generate_xray_profile 1
  if panel_configured && confirm "Отправить профиль без ext:-правил в Panel?"; then
    load_module panel
    panel_push_profile
  fi
  compose_edit geo-remove "$GEO_DIR"
  manager_compose up -d --remove-orphans
  systemctl disable --now remnanode-geo-update.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/remnanode-geo-update.{service,timer} "$GEO_UPDATER"
  systemctl daemon-reload
  ok "Geo roscomvpn отключён."
}

set_ru_policy() {
  load_state
  echo "Что делать с РФ-сайтами и белыми списками, если трафик пришёл на ноду:"
  echo "1. block  — блокировать (клиент должен ходить к ним напрямую; рекомендуется)"
  echo "2. direct — выпускать с IP ноды"
  echo "3. warp   — выпускать через WARP"
  local choice
  read -r -p "Выбор [1]: " choice
  case "${choice:-1}" in
    1) RU_POLICY="block" ;;
    2) RU_POLICY="direct" ;;
    3)
      [[ "$WARP_OUTBOUND" == "1" ]] || die "Сначала установи WARP и включи WARP outbound."
      RU_POLICY="warp"
      ;;
    *) die "Некорректный выбор." ;;
  esac
  save_state
  generate_xray_profile 1
}

toggle_ads_block() {
  load_state
  if [[ "$BLOCK_ADS" == "1" ]]; then BLOCK_ADS="0"; else BLOCK_ADS="1"; fi
  save_state
  ok "Блокировка рекламы: $([[ "$BLOCK_ADS" == 1 ]] && echo включена || echo выключена)"
  generate_xray_profile 1
}

routing_menu() {
  while true; do
    clear || true
    load_state
    print_header
    echo -e "${C_BOLD}Routing${C_RESET}"
    echo
    echo "Схема: РФ + белые списки → напрямую у клиента (на ноде: ${RU_POLICY}), торренты → блок, остальное → прокси."
    echo "Geo: $([[ "$GEO_ENABLED" == 1 ]] && echo "roscomvpn (ext:${GEO_SITE_FILE})" || echo "встроенные geosite/geoip Xray")   Реклама: $([[ "$BLOCK_ADS" == 1 ]] && echo блок || echo пропуск)"
    echo "DNS: РФ → ${DNS_RU}; остальное → ${DNS_FOREIGN}; перехват: $([[ "$DNS_HIJACK" == 1 ]] && echo вкл || echo выкл)"
    echo "Outbounds: WARP=${WARP_OUTBOUND} Psiphon=${PSIPHON_OUTBOUND} Tor=${TOR_OUTBOUND}"
    echo
    echo "1. Включить roscomvpn geo на ноде (скачать, смонтировать, автообновление)"
    echo "2. Обновить geo-файлы сейчас"
    echo "3. Политика для РФ-трафика на ноде (block / direct / warp)"
    echo "4. Блокировка рекламы: вкл/выкл"
    echo "5. Домены через WARP"
    echo "6. Домены через Psiphon"
    echo "7. Домены через Tor"
    echo "8. DNS: РФ / зарубежные резолверы, защита от утечек"
    echo "9. Пересобрать Xray profile"
    echo "10. Клиентская маршрутизация (Happ / шаблон подписки / приложения)"
    echo "11. Отправить профиль в Panel"
    echo "12. Отключить roscomvpn geo"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action geo_enable; pause ;;
      2) run_action geo_update_now; pause ;;
      3) run_action set_ru_policy; pause ;;
      4) run_action toggle_ads_block; pause ;;
      5) edit_routing_list warp; run_action generate_xray_profile; pause ;;
      6) edit_routing_list psiphon; run_action generate_xray_profile; pause ;;
      7) edit_routing_list tor; run_action generate_xray_profile; pause ;;
      8) dns_menu ;;
      9) run_action generate_xray_profile; pause ;;
      10) run_action show_client_routing; pause ;;
      11) run_action with_module panel panel_push_profile; pause ;;
      12) run_action geo_disable; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}
