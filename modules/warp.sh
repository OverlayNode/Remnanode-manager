#!/usr/bin/env bash
# RemnaNode Manager — модуль: WARP (Chara-Freedom/vps-warp): WireGuard-интерфейс warp без смены default route.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="4.1.0"

warp_installed() {
  [[ -f /etc/wireguard/warp.conf ]]
}

warp_install() {
  load_state
  if warp_installed; then
    ok "WARP уже установлен."
  else
    run_remote_installer "$WARP_INSTALL_URL" || die "Установка WARP прервана."
  fi
  ip link show warp >/dev/null 2>&1 || die "Интерфейс warp не появился."
  WARP_OUTBOUND="1"
  save_state
  generate_xray_profile 1
  ok "WARP outbound включён. Домены: $(routing_list_file warp)"
}

warp_test() {
  ip link show warp >/dev/null 2>&1 || die "Интерфейс warp не найден."
  info "Проверка выхода через интерфейс warp:"
  curl -4 -fsS --max-time 15 --interface warp https://www.cloudflare.com/cdn-cgi/trace \
    | grep -E '^(ip|loc|warp)=' || die "Запрос через warp не прошёл."
}

warp_status() {
  if command -v vps-warp >/dev/null 2>&1; then
    vps-warp || true
  else
    wg show warp 2>/dev/null || warn "WARP не установлен."
  fi
}

warp_uninstall() {
  confirm_no_default "Удалить WARP (wg-quick@warp, watchdog, /etc/wireguard/warp.conf)?" || return 0
  load_state
  WARP_OUTBOUND="0"
  [[ "$RU_POLICY" == "warp" ]] && RU_POLICY="block"
  save_state
  generate_xray_profile 1
  systemctl disable --now wg-quick@warp warp-watchdog.timer warp-watchdog.service 2>/dev/null || true
  rm -rf /opt/vps-warp /etc/wireguard/warp.conf /usr/local/bin/vps-warp
  rm -f /etc/systemd/system/warp-watchdog.{service,timer}
  systemctl daemon-reload
  ok "WARP удалён. Не забудь отправить профиль в Panel."
}

warp_menu() {
  while true; do
    clear || true
    load_state
    echo -e "${C_BOLD}WARP${C_RESET} — Cloudflare WARP как outbound Xray (интерфейс warp, default route не меняется)"
    echo "Установлен: $(warp_installed && echo да || echo нет)   Outbound в профиле: ${WARP_OUTBOUND}"
    echo
    echo "1. Установить WARP и включить outbound"
    echo "2. Статус (vps-warp)"
    echo "3. Проверить выход через WARP"
    echo "4. Домены через WARP"
    echo "5. Outbound: вкл/выкл без удаления"
    echo "6. Удалить WARP"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action warp_install; pause ;;
      2) run_action warp_status; pause ;;
      3) run_action warp_test; pause ;;
      4) edit_routing_list warp; run_action generate_xray_profile; pause ;;
      5) run_action toggle_outbound WARP_OUTBOUND; pause ;;
      6) run_action warp_uninstall; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}
