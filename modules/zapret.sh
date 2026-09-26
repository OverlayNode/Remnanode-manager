#!/usr/bin/env bash
# RemnaNode Manager — модуль: Zapret2 (bol-van/zapret2): обход DPI для исходящего трафика сервера.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="4.2.0"

ZAPRET_REPO="bol-van/zapret2"
ZAPRET_DIR="/opt/zapret2"

zapret_installed() {
  [[ -d "$ZAPRET_DIR" ]]
}

zapret_install() {
  local api tag asset asset_url sums_url tmp_dir expected actual src
  api="$(curl -fsS --max-time 30 "https://api.github.com/repos/${ZAPRET_REPO}/releases/latest")" \
    || die "Не удалось получить релиз ${ZAPRET_REPO}."
  tag="$(jq -r .tag_name <<<"$api")"
  # Нужен полный архив для Linux, а не сборка для OpenWrt.
  asset="$(jq -r '.assets[].name | select(test("^zapret2-v[0-9.]+\\.tar\\.gz$"))' <<<"$api" | head -n1)"
  [[ -n "$asset" ]] || die "В релизе ${tag} не найден архив для Linux."
  asset_url="$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$api")"
  sums_url="$(jq -r '.assets[] | select(.name == "sha256sum.txt") | .browser_download_url' <<<"$api")"

  info "Релиз: ${tag} — ${asset}"
  tmp_dir="$(mktemp -d /tmp/zapret2.XXXXXX)"
  curl --proto '=https' -fsSL "$asset_url" -o "${tmp_dir}/${asset}" || { rm -rf "$tmp_dir"; die "Загрузка не удалась."; }

  if [[ -n "$sums_url" ]] && curl --proto '=https' -fsSL "$sums_url" -o "${tmp_dir}/sha256sum.txt"; then
    expected="$(awk -v name="$asset" '$2 == name || $2 == "*"name {print $1}' "${tmp_dir}/sha256sum.txt")"
    actual="$(sha256sum "${tmp_dir}/${asset}" | cut -d' ' -f1)"
    [[ -n "$expected" && "$expected" == "$actual" ]] || { rm -rf "$tmp_dir"; die "SHA256 архива не совпадает с sha256sum.txt релиза."; }
    ok "SHA256 архива проверен."
  else
    warn "sha256sum.txt не найден в релизе — контрольная сумма не проверена."
  fi

  tar -xzf "${tmp_dir}/${asset}" -C "$tmp_dir"
  src="$(find "$tmp_dir" -mindepth 2 -maxdepth 2 -name install_easy.sh -printf '%h\n' | head -n1)"
  [[ -n "$src" ]] || { rm -rf "$tmp_dir"; die "install_easy.sh не найден в архиве."; }

  echo
  warn "Дальше запускается интерактивный install_easy.sh из ${ZAPRET_REPO}."
  warn "Выбирай firewall nftables/iptables по системе. Zapret2 влияет на ИСХОДЯЩИЙ трафик сервера,"
  warn "включая выход клиентов Xray — полезно для нод в РФ для доступа к заблокированным ресурсам."
  confirm "Продолжить?" || { rm -rf "$tmp_dir"; return 0; }
  (cd "$src" && ./install_easy.sh) || warn "install_easy.sh завершился с ошибкой."
  rm -rf "$tmp_dir"
}

zapret_blockcheck() {
  [[ -x "${ZAPRET_DIR}/blockcheck2.sh" ]] || die "blockcheck2.sh не найден — сначала установи Zapret2."
  (cd "$ZAPRET_DIR" && ./blockcheck2.sh) || true
}

zapret_uninstall() {
  [[ -x "${ZAPRET_DIR}/uninstall_easy.sh" ]] || die "uninstall_easy.sh не найден."
  confirm_no_default "Удалить Zapret2?" || return 0
  (cd "$ZAPRET_DIR" && ./uninstall_easy.sh) || true
}

zapret_menu() {
  while true; do
    clear || true
    echo -e "${C_BOLD}Zapret2${C_RESET} — обход DPI для исходящих соединений (актуально для серверов в РФ)"
    echo "Сервис: $(systemctl is-active zapret2 2>/dev/null || echo 'не установлен')   Каталог: ${ZAPRET_DIR}"
    echo
    echo "1. Установить / обновить Zapret2"
    echo "2. Перезапустить"
    echo "3. Подобрать стратегию для домена (blockcheck2)"
    echo "4. Редактировать конфиг"
    echo "5. Журнал"
    echo "6. Удалить"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action zapret_install; pause ;;
      2) systemctl restart zapret2 || warn "Сервис zapret2 не найден."; pause ;;
      3) run_action zapret_blockcheck; pause ;;
      4)
        if [[ -f "${ZAPRET_DIR}/config" ]]; then
          "${EDITOR:-nano}" "${ZAPRET_DIR}/config" && systemctl restart zapret2 || true
        else
          warn "Конфиг не найден."
        fi
        pause
        ;;
      5) journalctl -u zapret2 -n 100 --no-pager 2>/dev/null | less -R +G || true ;;
      6) run_action zapret_uninstall; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}
