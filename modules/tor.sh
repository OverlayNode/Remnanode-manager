#!/usr/bin/env bash
# RemnaNode Manager — модуль: Tor: SOCKS 127.0.0.1:9050, мосты obfs4/webtunnel/snowflake для РФ.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="4.1.0"

TOR_BRIDGES_FILE="/etc/tor/torrc.d/remnanode-bridges.conf"

tor_install() {
  load_state
  export DEBIAN_FRONTEND=noninteractive
  apt_get_wait update -y
  apt_get_wait install -y tor
  mkdir -p /etc/tor/torrc.d
  grep -q '^%include /etc/tor/torrc.d' /etc/tor/torrc 2>/dev/null \
    || printf '\n%%include /etc/tor/torrc.d/*.conf\n' >> /etc/tor/torrc
  grep -qE '^SocksPort' /etc/tor/torrc || printf 'SocksPort 127.0.0.1:9050\n' >> /etc/tor/torrc
  systemctl enable --now tor
  systemctl restart tor
  TOR_OUTBOUND="1"
  save_state
  generate_xray_profile 1
  ok "Tor установлен, outbound включён. Домены: $(routing_list_file tor)"
}

tor_configure_bridges() {
  command -v tor >/dev/null 2>&1 || die "Сначала установи Tor."
  echo "Мосты нужны, если прямой доступ к сети Tor заблокирован (сервер в РФ)."
  echo "Получить мосты: https://bridges.torproject.org/options или Telegram-бот @GetBridgesBot."
  echo "Поддерживаются транспорты obfs4, webtunnel и snowflake (строки из Tor Browser)."
  echo
  echo "1. Вставить строки мостов"
  echo "2. Отключить мосты"
  local choice
  read -r -p "Выбор: " choice
  mkdir -p /etc/tor/torrc.d
  case "$choice" in
    1)
      echo "Вставь строки мостов (пустая строка — конец):"
      local line transport
      local -a bridges=()
      local -A transports=()
      while read -r line && [[ -n "$line" ]]; do
        line="${line#Bridge }"
        transport="${line%% *}"
        case "$transport" in
          obfs4|webtunnel|snowflake) ;;
          *) warn "Неизвестный транспорт, строка пропущена: ${line}"; continue ;;
        esac
        [[ "$line" =~ ^[a-z0-9]+\ [^[:space:]]+\ [0-9A-Fa-f]{40}(\ [^[:space:]]+)*$ ]] \
          || { warn "Некорректная строка моста, пропущена: ${line}"; continue; }
        bridges+=("Bridge ${line}")
        transports["$transport"]=1
      done
      ((${#bridges[@]} > 0)) || die "Не введено ни одного моста."

      local -a plugins=()
      if [[ -n "${transports[obfs4]:-}" ]]; then
        apt_get_wait install -y obfs4proxy || die "Не удалось установить obfs4proxy."
        plugins+=("ClientTransportPlugin obfs4 exec $(command -v obfs4proxy || echo /usr/bin/obfs4proxy)")
      fi
      if [[ -n "${transports[snowflake]:-}" ]]; then
        apt_get_wait install -y snowflake-client || die "Пакет snowflake-client недоступен в этом дистрибутиве."
        plugins+=("ClientTransportPlugin snowflake exec $(command -v snowflake-client || echo /usr/bin/snowflake-client)")
      fi
      if [[ -n "${transports[webtunnel]:-}" ]]; then
        apt_get_wait install -y webtunnel-client 2>/dev/null || apt_get_wait install -y webtunnel 2>/dev/null \
          || die "Клиент webtunnel недоступен в репозиториях этого дистрибутива — используй obfs4."
        plugins+=("ClientTransportPlugin webtunnel exec $(command -v webtunnel-client || command -v client || echo /usr/bin/webtunnel-client)")
      fi

      {
        echo "# RemnaNode Manager — мосты Tor"
        echo "UseBridges 1"
        printf '%s\n' "${plugins[@]}" "${bridges[@]}"
      } > "$TOR_BRIDGES_FILE"
      ;;
    2) rm -f "$TOR_BRIDGES_FILE" ;;
    *) return 0 ;;
  esac
  tor --verify-config -f /etc/tor/torrc >/dev/null || die "Конфигурация Tor некорректна."
  systemctl restart tor
  ok "Tor перезапущен. Bootstrap может занять 1–3 минуты."
}

tor_test() {
  curl -fsS --max-time 60 --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip \
    || die "Запрос через Tor не прошёл (идёт bootstrap или сеть заблокирована — настрой мосты)."
  echo
}

tor_menu() {
  while true; do
    clear || true
    load_state
    echo -e "${C_BOLD}Tor${C_RESET} — outbound через SOCKS 127.0.0.1:9050"
    echo "Сервис: $(systemctl is-active tor 2>/dev/null || echo 'не установлен')   Outbound: ${TOR_OUTBOUND}   Мосты: $([[ -f "$TOR_BRIDGES_FILE" ]] && echo да || echo нет)"
    echo
    echo "1. Установить Tor и включить outbound"
    echo "2. Мосты (obfs4 / webtunnel / snowflake)"
    echo "3. Проверить выход через Tor"
    echo "4. Домены через Tor"
    echo "5. Outbound: вкл/выкл"
    echo "6. Журнал Tor"
    echo "7. Удалить Tor"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action tor_install; pause ;;
      2) run_action tor_configure_bridges; pause ;;
      3) run_action tor_test; pause ;;
      4) edit_routing_list tor; run_action generate_xray_profile; pause ;;
      5) run_action toggle_outbound TOR_OUTBOUND; pause ;;
      6) journalctl -u tor -u tor@default -n 100 --no-pager 2>/dev/null | less -R +G || true ;;
      7)
        if confirm_no_default "Удалить Tor?"; then
          TOR_OUTBOUND="0"
          save_state
          run_action generate_xray_profile
          apt-get purge -y tor obfs4proxy snowflake-client >/dev/null 2>&1 || true
          rm -f "$TOR_BRIDGES_FILE"
        fi
        pause
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}
