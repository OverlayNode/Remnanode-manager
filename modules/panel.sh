#!/usr/bin/env bash
# RemnaNode Manager — модуль: Remnawave Panel API: Config Profiles с diff и backup.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="4.1.0"

panel_configure() {
  local url token old_umask
  panel_load || true
  read -r -p "URL панели (https://panel.example.com)${PANEL_URL:+ [${PANEL_URL}]}: " url
  url="${url:-$PANEL_URL}"
  [[ "$url" =~ ^https?://[^[:space:]\'\"]+$ ]] || die "URL должен начинаться с http:// или https://"
  read -r -s -p "API-токен (Remnawave → Settings → API Tokens): " token
  echo
  token="${token:-$PANEL_TOKEN}"
  [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die "Токен пуст или содержит неподдерживаемые символы."

  mkdir -p "$BASE_DIR"
  old_umask="$(umask)"
  umask 077
  printf 'PANEL_URL=%s\nPANEL_TOKEN=%s\n' "$url" "$token" > "$PANEL_ENV_FILE"
  chmod 600 "$PANEL_ENV_FILE"
  umask "$old_umask"

  if panel_request GET /api/config-profiles | jq -e '.response' >/dev/null 2>&1; then
    ok "Panel API доступен, токен принят."
  else
    warn "Данные сохранены, но запрос к /api/config-profiles не прошёл."
  fi
  rm -f "${RUNTIME_CACHE}/panel.status" 2>/dev/null || true
}

panel_list_profiles() {
  panel_request GET /api/config-profiles \
    | jq -r '.response.configProfiles[]? | "\(.uuid)  \(.name)  (inbounds: \(.config.inbounds // [] | length))"'
}

panel_select_profile() {
  local profiles uuid
  profiles="$(panel_request GET /api/config-profiles)" || die "Не удалось получить Config Profiles."
  echo
  jq -r '.response.configProfiles[]? | "\(.uuid)  \(.name)"' <<<"$profiles" | nl -w2 -s'. '
  echo
  local choice
  read -r -p "Номер профиля${PANEL_PROFILE_UUID:+ (Enter = текущий ${PANEL_PROFILE_UUID})}: " choice
  if [[ -z "$choice" && -n "$PANEL_PROFILE_UUID" ]]; then
    return 0
  fi
  [[ "$choice" =~ ^[0-9]+$ ]] || die "Нужно число."
  uuid="$(jq -r --argjson i "$((choice - 1))" '.response.configProfiles[$i].uuid // empty' <<<"$profiles")"
  [[ -n "$uuid" ]] || die "Профиль не найден."
  PANEL_PROFILE_UUID="$uuid"
  save_state
}

redact_secrets() {
  sed -E 's/("privateKey"[[:space:]]*:[[:space:]]*")[^"]+/\1[REDACTED]/g'
}

panel_push_profile() {
  load_state
  [[ -f "$PROFILE_FILE" ]] || generate_xray_profile 1
  panel_select_profile
  [[ -n "$PANEL_PROFILE_UUID" ]] || die "Профиль не выбран."

  local current current_config new_config payload mode_choice
  current="$(mktemp)"
  current_config="$(mktemp)"
  new_config="$(mktemp)"
  payload="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$current' '$current_config' '$new_config' '$payload'" RETURN

  panel_request GET "/api/config-profiles/${PANEL_PROFILE_UUID}" > "$current" \
    || die "Не удалось скачать текущий профиль."
  jq '.response.config' "$current" > "$current_config"

  mkdir -p "$BACKUP_DIR"
  cp "$current" "${BACKUP_DIR}/panel-profile-${PANEL_PROFILE_UUID}-$(date +%Y%m%d-%H%M%S).json"
  chmod 600 "${BACKUP_DIR}"/panel-profile-*.json

  echo
  echo "Режим обновления:"
  echo "1. merge — оставить inbound'ы панели, заменить outbounds / routing / dns (рекомендуется)"
  echo "2. full  — полностью заменить профиль сгенерированным (нужны inbound'ы Selfsteal)"
  read -r -p "Выбор [1]: " mode_choice
  case "${mode_choice:-1}" in
    1) jq --slurpfile gen "$PROFILE_FILE" '. + {outbounds: $gen[0].outbounds, routing: $gen[0].routing, dns: $gen[0].dns}' \
         "$current_config" > "$new_config" ;;
    2)
      [[ "$(jq '.inbounds | length' "$PROFILE_FILE")" != "0" ]] \
        || die "В сгенерированном профиле нет inbound'ов — используй merge."
      cp "$PROFILE_FILE" "$new_config"
      ;;
    *) die "Некорректный выбор." ;;
  esac

  echo
  info "Diff (приватные ключи скрыты):"
  diff -u <(jq -S . "$current_config" | redact_secrets) <(jq -S . "$new_config" | redact_secrets) || true
  echo

  if cmp -s <(jq -S . "$current_config") <(jq -S . "$new_config"); then
    ok "Изменений нет."
    return 0
  fi

  confirm_no_default "Отправить профиль в Panel?" || { warn "Отменено."; return 0; }

  jq -n --arg uuid "$PANEL_PROFILE_UUID" --slurpfile config "$new_config" \
    '{uuid: $uuid, config: $config[0]}' > "$payload"
  panel_request PATCH /api/config-profiles "$payload" | jq -r '.response.name // "ok"' >/dev/null \
    || die "Panel отклонила изменение. Backup: ${BACKUP_DIR}"
  ok "Config Profile обновлён. Backup старой версии: ${BACKUP_DIR}"
}

panel_menu() {
  while true; do
    clear || true
    load_state
    echo -e "${C_BOLD}Remnawave Panel API${C_RESET}"
    echo
    if panel_load; then
      echo "URL: ${PANEL_URL}"
      echo "Профиль: ${PANEL_PROFILE_UUID:-не выбран}"
    else
      echo "Не настроено. Без токена статус Panel в шапке определяется по связи панели с нодой."
    fi
    echo
    echo "1. Настроить URL и API-токен"
    echo "2. Список Config Profiles"
    echo "3. Отправить сгенерированный профиль в Panel (diff + backup)"
    echo "4. Удалить сохранённый токен"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action panel_configure; pause ;;
      2) run_action panel_list_profiles; pause ;;
      3) run_action panel_push_profile; pause ;;
      4) confirm_no_default "Удалить ${PANEL_ENV_FILE}?" && rm -f "$PANEL_ENV_FILE"; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}
