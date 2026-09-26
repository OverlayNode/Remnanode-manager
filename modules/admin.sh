#!/usr/bin/env bash
# RemnaNode Manager — модуль: администрирование сервера и бэкапы.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="4.1.0"

docker_cleanup() {
  docker_available || die "Docker недоступен."
  docker system df
  echo
  confirm_no_default "Удалить остановленные контейнеры, неиспользуемые образы и build cache?" || return 0
  docker system prune -af
}

enable_bbr() {
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
    ok "BBR уже включён."
    return 0
  fi
  cat > /etc/sysctl.d/99-remnanode-bbr.conf <<'EOF'
# RemnaNode Manager — BBR + fq
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  ok "TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

create_swap() {
  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    swapon --show
    confirm_no_default "Swap уже есть. Создать дополнительный /swapfile-remnanode?" || return 0
  fi
  local size
  read -r -p "Размер swap в GB [2]: " size
  size="${size:-2}"
  [[ "$size" =~ ^[0-9]+$ ]] && ((size >= 1 && size <= 64)) || die "Некорректный размер."
  local file="/swapfile-remnanode"
  [[ -e "$file" ]] && die "${file} уже существует."
  fallocate -l "${size}G" "$file" 2>/dev/null || dd if=/dev/zero of="$file" bs=1M count=$((size * 1024)) status=progress
  chmod 600 "$file"
  mkswap "$file" >/dev/null
  swapon "$file"
  grep -q "^${file} " /etc/fstab || echo "${file} none swap sw 0 0" >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-remnanode-swap.conf
  ok "Swap ${size} GB включён."
}

PING_SYSCTL_FILE="/etc/sysctl.d/99-remnanode-ping.conf"

ping_status() {
  echo "IPv4 echo: $([[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" == 1 ]] && echo ОТКЛЮЧЁН || echo включён)"
  echo "IPv6 echo: $([[ "$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null)" == 1 ]] && echo ОТКЛЮЧЁН || echo включён)"
}

ping_toggle() {
  ping_status
  if [[ -f "$PING_SYSCTL_FILE" ]]; then
    confirm "Включить ответы на ping?" || return 0
    rm -f "$PING_SYSCTL_FILE"
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null
    sysctl -w net.ipv6.icmp.echo_ignore_all=0 >/dev/null 2>&1 || true
  else
    warn "Отключаются только ответы на Echo Request; ICMP-ошибки, PMTUD и IPv6 ND продолжают работать."
    confirm "Отключить ответы на ping?" || return 0
    {
      echo '# RemnaNode Manager — не отвечать на ICMP echo'
      echo 'net.ipv4.icmp_echo_ignore_all = 1'
      [[ -e /proc/sys/net/ipv6/icmp/echo_ignore_all ]] && echo 'net.ipv6.icmp.echo_ignore_all = 1'
    } > "$PING_SYSCTL_FILE"
    sysctl -p "$PING_SYSCTL_FILE" >/dev/null
  fi
  ping_status
}

ufw_menu() {
  while true; do
    clear || true
    echo -e "${C_BOLD}Firewall (UFW)${C_RESET}"
    echo
    ufw status numbered 2>/dev/null || warn "UFW не установлен."
    echo
    echo "1. Открыть порт"
    echo "2. Закрыть порт (удалить правило по номеру)"
    echo "3. Разрешить IP/CIDR полностью"
    echo "4. Переприменить правила ноды"
    echo
    echo "0. Назад"
    echo
    local choice value
    read -r -p "Выбор: " choice
    case "$choice" in
      1)
        read -r -p "Порт/протокол (например 8443/tcp): " value
        [[ "$value" =~ ^[0-9]{1,5}/(tcp|udp)$ ]] && validate_port "${value%/*}" \
          && ufw allow "$value" comment remnanode-manager-user || warn "Некорректный ввод."
        pause
        ;;
      2)
        read -r -p "Номер правила: " value
        [[ "$value" =~ ^[0-9]+$ ]] && ufw --force delete "$value" || warn "Некорректный номер."
        pause
        ;;
      3)
        read -r -p "IP/CIDR: " value
        validate_panel_network "$value" && [[ -n "$value" ]] && ufw allow from "$value" comment remnanode-manager-user \
          || warn "Некорректный адрес."
        pause
        ;;
      4)
        load_state
        if is_selfsteal_mode; then run_action configure_firewall selfsteal; else run_action configure_firewall basic; fi
        pause
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

install_fail2ban() {
  export DEBIAN_FRONTEND=noninteractive
  apt_get_wait install -y fail2ban
  cat > /etc/fail2ban/jail.d/remnanode-sshd.conf <<EOF
[sshd]
enabled = true
port = $(detect_ssh_port)
maxretry = 5
findtime = 10m
bantime = 1h
backend = systemd
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  fail2ban-client status sshd || true
}

system_upgrade() {
  confirm "Обновить пакеты системы (apt upgrade)?" || return 0
  export DEBIAN_FRONTEND=noninteractive
  apt_get_wait update -y
  apt_get_wait -o Dpkg::Options::=--force-confold upgrade -y
  [[ -f /var/run/reboot-required ]] && warn "Требуется перезагрузка."
  return 0
}

install_command() {
  local target="/usr/local/bin/remnanode" tmp_dir name file new_version from_clone=0
  tmp_dir="$(mktemp -d)"
  # Локальная копия — только при запуске из клона репозитория; иначе (в том
  # числе из уже установленной команды) скачиваем свежую версию.
  [[ -d "${SCRIPT_DIR}/modules" && -f "${SCRIPT_DIR}/install.sh" ]] && from_clone=1

  if ((from_clone)); then
    cp "${SCRIPT_DIR}/install.sh" "${tmp_dir}/install.sh"
  else
    curl --proto '=https' --tlsv1.2 -fsSL "${RNM_RAW_URL}/install.sh" -o "${tmp_dir}/install.sh" \
      || { rm -rf "$tmp_dir"; die "Загрузка install.sh не удалась."; }
  fi
  bash -n "${tmp_dir}/install.sh" || { rm -rf "$tmp_dir"; die "install.sh не прошёл проверку синтаксиса."; }
  new_version="$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "${tmp_dir}/install.sh")"
  [[ -n "$new_version" ]] || { rm -rf "$tmp_dir"; die "Не удалось определить версию скрипта."; }

  for name in $RNM_MODULES; do
    file="${tmp_dir}/${name}.sh"
    if ((from_clone)); then
      cp "${SCRIPT_DIR}/modules/${name}.sh" "$file"
    else
      curl --proto '=https' --tlsv1.2 -fsSL "${RNM_RAW_URL}/modules/${name}.sh" -o "$file" \
        || { rm -rf "$tmp_dir"; die "Загрузка модуля ${name} не удалась."; }
    fi
    bash -n "$file" && grep -qx "RNM_MODULE_VERSION=\"${new_version}\"" "$file" \
      || { rm -rf "$tmp_dir"; die "Модуль ${name} не совпадает с версией ${new_version}."; }
  done

  install -d -m 755 "$RNM_LIB_DIR"
  find "$RNM_LIB_DIR" -maxdepth 1 -name '*.sh' -delete
  for name in $RNM_MODULES; do
    install -m 644 "${tmp_dir}/${name}.sh" "${RNM_LIB_DIR}/${name}.sh"
  done
  install -m 755 "${tmp_dir}/install.sh" "$target"
  rm -rf "$tmp_dir"
  ok "Команда remnanode ${new_version} установлена, модули: ${RNM_LIB_DIR} (обновить — повтори этот пункт)."

  # Остатки модульного CLI версии 3.x больше не используются.
  if [[ -d /opt/remnanode-manager ]] && confirm "Найден старый модульный CLI в /opt/remnanode-manager. Удалить?"; then
    rm -rf /opt/remnanode-manager
    ok "Старый CLI удалён."
  fi
}

admin_menu() {
  while true; do
    clear || true
    print_header
    echo -e "${C_BOLD}Администрирование сервера${C_RESET}"
    echo
    echo "1. Firewall (UFW)"
    echo "2. Включить BBR"
    echo "3. Создать swap"
    echo "4. Ответы на ping: вкл/выкл"
    echo "5. Fail2ban для SSH"
    echo "6. Обновить пакеты системы"
    echo "7. Очистка Docker"
    echo "8. Установить команду remnanode (запуск без curl)"
    echo "9. Перезагрузить сервер"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) ufw_menu ;;
      2) run_action enable_bbr; pause ;;
      3) run_action create_swap; pause ;;
      4) run_action ping_toggle; pause ;;
      5) run_action install_fail2ban; pause ;;
      6) run_action system_upgrade; pause ;;
      7) run_action docker_cleanup; pause ;;
      8) run_action install_command; pause ;;
      9) confirm_no_default "Перезагрузить сервер сейчас?" && systemctl reboot ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

backup_create() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  local file
  file="${BACKUP_DIR}/remnanode-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$file" -C / \
    --exclude="${BASE_DIR#/}/backups" \
    --exclude="${BASE_DIR#/}/.cache" \
    "${BASE_DIR#/}" 2>/dev/null
  chmod 600 "$file"
  ok "Backup: ${file} ($(du -h "$file" | cut -f1))"
  warn "Архив содержит SECRET_KEY, Reality private key и сертификаты — не публикуй его."
}

backup_list() {
  find "$BACKUP_DIR" -maxdepth 1 -name 'remnanode-*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM  %10s  %f\n' 2>/dev/null | sort -r
}

backup_restore() {
  local -a files=()
  mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -name 'remnanode-*.tar.gz' -printf '%f\n' 2>/dev/null | sort -r)
  ((${#files[@]} > 0)) || die "Бэкапов нет."
  local index choice
  for index in "${!files[@]}"; do
    printf '%2d. %s\n' "$((index + 1))" "${files[$index]}"
  done
  read -r -p "Номер: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#files[@]})) || die "Некорректный выбор."
  local file="${BACKUP_DIR}/${files[$((choice - 1))]}"
  warn "Текущие файлы ${BASE_DIR} будут заменены (кроме backups)."
  confirm_no_default "Восстановить ${file}?" || return 0
  backup_create
  [[ -f "$NODE_COMPOSE_FILE" ]] && manager_compose down || true
  tar -xzf "$file" -C /
  load_state
  [[ -f "$NODE_COMPOSE_FILE" ]] && manager_compose up -d
  ok "Восстановлено."
}

backup_menu() {
  while true; do
    clear || true
    echo -e "${C_BOLD}Бэкапы${C_RESET} (${BACKUP_DIR})"
    echo
    backup_list || true
    echo
    echo "1. Создать бэкап"
    echo "2. Восстановить"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action backup_create; pause ;;
      2) run_action backup_restore; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}
