#!/usr/bin/env bash
# RemnaNode Manager — модуль: Psiphon (Chara-Freedom/vps-psiphon): локальный SOCKS5 на 127.0.0.1.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="4.2.0"

psiphon_installed() {
  [[ -f /etc/default/vps-psiphon ]]
}

psiphon_install() {
  load_state
  command -v docker >/dev/null 2>&1 || die "Нужен Docker."
  warn "Psiphon распознаётся DPI — не используй его на серверах внутри страны с блокировками для выхода в зарубежный интернет."
  if ! psiphon_installed; then
    local region
    read -r -p "Страна выхода (ISO-код, например DE; несколько через запятую; Enter = авто): " region
    local -a args=(--bind-loopback)
    if [[ -n "$region" ]]; then
      [[ "$region" =~ ^[A-Za-z]{2}(,[A-Za-z]{2})*$ ]] || die "Некорректный код страны."
      args+=(--region "${region^^}")
    fi
    run_remote_installer "$PSIPHON_INSTALL_URL" "${args[@]}" || die "Установка Psiphon прервана."
  fi

  local port
  port="$(sed -n 's/^SOCKS_PORT=//p' /etc/default/vps-psiphon 2>/dev/null | tr -d "'\"" | head -n1)"
  PSIPHON_ADDR="127.0.0.1"
  PSIPHON_PORT="${port:-1080}"
  validate_port "$PSIPHON_PORT" || PSIPHON_PORT="1080"
  PSIPHON_OUTBOUND="1"
  save_state
  generate_xray_profile 1
  ok "Psiphon outbound включён (${PSIPHON_ADDR}:${PSIPHON_PORT}). Домены: $(routing_list_file psiphon)"
}

psiphon_test() {
  load_state
  curl -4 -fsS --max-time 20 --socks5-hostname "${PSIPHON_ADDR}:${PSIPHON_PORT}" \
    https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc)=' || die "Запрос через Psiphon не прошёл."
}

psiphon_menu() {
  while true; do
    clear || true
    load_state
    echo -e "${C_BOLD}Psiphon${C_RESET} — выход через сеть Psiphon (SOCKS5 127.0.0.1, только TCP)"
    echo "Установлен: $(psiphon_installed && echo да || echo нет)   Outbound: ${PSIPHON_OUTBOUND} (${PSIPHON_ADDR}:${PSIPHON_PORT})"
    echo
    echo "1. Установить Psiphon и включить outbound"
    echo "2. Статус (vps-psiphon)"
    echo "3. Проверить выход"
    echo "4. Сменить страну выхода"
    echo "5. Новый IP выхода (rotate)"
    echo "6. Домены через Psiphon"
    echo "7. Outbound: вкл/выкл"
    echo "8. Удалить Psiphon"
    echo
    echo "0. Назад"
    echo
    local choice region
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action psiphon_install; pause ;;
      2) vps-psiphon 2>/dev/null || warn "vps-psiphon не установлен."; pause ;;
      3) run_action psiphon_test; pause ;;
      4)
        read -r -p "Страна (ISO): " region
        [[ "$region" =~ ^[A-Za-z]{2}$ ]] && vps-psiphon region "${region^^}" || warn "Некорректный код."
        pause
        ;;
      5) vps-psiphon rotate || true; pause ;;
      6) edit_routing_list psiphon; run_action generate_xray_profile; pause ;;
      7) run_action toggle_outbound PSIPHON_OUTBOUND; pause ;;
      8)
        if confirm_no_default "Удалить Psiphon?"; then
          vps-psiphon uninstall || true
          PSIPHON_OUTBOUND="0"
          save_state
          run_action generate_xray_profile
        fi
        pause
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}
