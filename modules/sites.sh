#!/usr/bin/env bash
# RemnaNode Manager — модуль: сайты-заглушки: каталог шаблонов и уникализация при каждом деплое.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="4.2.0"

# Каталог шаблонов: локальный (если скрипт запущен из клона) или кеш из GitHub.
templates_dir() {
  if [[ -d "${SCRIPT_DIR}/templates/sites" ]] \
    && find "${SCRIPT_DIR}/templates/sites" -mindepth 2 -maxdepth 2 -name index.html -print -quit | grep -q .; then
    printf '%s' "${SCRIPT_DIR}/templates/sites"
    return 0
  fi
  templates_fetch 0 >&2 || return 1
  printf '%s' "${CACHE_DIR}/sites"
}

templates_fetch() {
  local force="${1:-0}" target="${CACHE_DIR}/sites" tmp_dir
  if [[ "$force" != "1" && -d "$target" ]] \
    && [[ -n "$(find "$target" -maxdepth 0 -mmin -1440 2>/dev/null)" ]]; then
    return 0
  fi

  info "Загружаю каталог шаблонов из ${RNM_REPO}@${RNM_REF}..."
  mkdir -p "$CACHE_DIR"
  tmp_dir="$(mktemp -d "${CACHE_DIR}/fetch.XXXXXX")"
  if ! curl --proto '=https' --tlsv1.2 -fsSL \
    "https://codeload.github.com/${RNM_REPO}/tar.gz/refs/heads/${RNM_REF}" \
    -o "${tmp_dir}/repo.tar.gz"; then
    rm -rf "$tmp_dir"
    [[ -d "$target" ]] && { warn "Не удалось обновить каталог — использую кеш."; return 0; }
    err "Не удалось скачать каталог шаблонов."
    return 1
  fi

  tar -xzf "${tmp_dir}/repo.tar.gz" -C "$tmp_dir" --wildcards '*/templates/sites/*' 2>/dev/null \
    || { rm -rf "$tmp_dir"; err "Архив не содержит templates/sites."; return 1; }

  local extracted
  extracted="$(find "$tmp_dir" -mindepth 3 -maxdepth 3 -type d -path '*/templates/sites' | head -n1)"
  [[ -n "$extracted" ]] || { rm -rf "$tmp_dir"; err "Каталог templates/sites не найден в архиве."; return 1; }

  rm -rf "$target"
  mv "$extracted" "$target"
  rm -rf "$tmp_dir"
  touch "$target"
}

templates_names() {
  local dir="$1" entry
  for entry in "$dir"/*/; do
    [[ -f "${entry}index.html" ]] && basename "$entry"
  done
}

# Короткое описание шаблона из manifest.json (пусто, если его нет).
template_title() {
  local manifest="$1/manifest.json"
  [[ -f "$manifest" ]] && command -v jq >/dev/null 2>&1 || return 0
  jq -r '.description // empty' "$manifest" 2>/dev/null || true
}

random_brand() {
  local prefix suffix
  prefix="$(random_pick Nova Aster Lumen Vertex Orbit Nimbus Quanta Helio Cobalt Arcadia Pixel Stellar \
    Delta Northwind Silverline Echo Apex Terra Kite Polar Harbor Cedar Summit Atlas Beacon Crest Ember Fjord)"
  suffix="$(random_pick Cloud Labs Works Stack Hub Grid Base Flow Point Link Sync Forge Nest Wave Dock \
    Systems Digital Data Studio Networks Ops Soft)"
  printf '%s %s' "$prefix" "$suffix"
}

random_letters() {
  local count="$1" letters=abcdefghijklmnopqrstuvwxyz result="" i
  for ((i = 0; i < count; i++)); do
    result+="${letters:$(secure_random_int 0 25):1}"
  done
  printf '%s' "$result"
}

sed_escape_pattern() {
  printf '%s' "$1" | sed -e 's/[]\/$*.^|[]/\\&/g'
}

sed_escape_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

is_text_asset() {
  case "$1" in
    *.html|*.css|*.js|*.svg|*.txt|*.json|*.webmanifest|*.xml) return 0 ;;
    *) return 1 ;;
  esac
}

# Генерирует бессмысленные, но валидные CSS-правила — меняют хеш и размер CSS.
css_noise() {
  local prefix="$1" count i prop value
  count="$(secure_random_int 4 14)"
  for ((i = 0; i < count; i++)); do
    case "$(secure_random_int 0 5)" in
      0) prop="margin-top"; value="$(secure_random_int 0 9)px" ;;
      1) prop="letter-spacing"; value=".0$(secure_random_int 1 9)em" ;;
      2) prop="opacity"; value=".9$(secure_random_int 0 9)" ;;
      3) prop="padding-left"; value="$(secure_random_int 0 12)px" ;;
      4) prop="border-radius"; value="$(secure_random_int 2 18)px" ;;
      *) prop="line-height"; value="1.$(secure_random_int 2 8)" ;;
    esac
    printf '.%s%s{%s:%s}\n' "$prefix" "$(random_letters "$(secure_random_int 3 7)")" "$prop" "$value"
  done
}

# Рендерит шаблон в OUT_DIR с уникальным отпечатком. Не требует root и jq.
# Использование: site_render_template SRC_DIR OUT_DIR BRAND DOMAIN
site_render_template() {
  local src="$1" out="$2" brand="$3" domain="$4"
  [[ -f "${src}/index.html" ]] || { err "Шаблон не найден: ${src}"; return 1; }

  mkdir -p "$out"
  cp -R "${src}/." "$out/"
  rm -f "${out}/manifest.json" "${out}/preview.png" "${out}/README.md"

  local prefix hue hue2 build seed version year brand_slug asset_dir sed_script
  prefix="$(random_letters "$(secure_random_int 2 3)")-"
  hue="$(secure_random_int 0 359)"
  hue2="$(( (hue + $(secure_random_int 25 150)) % 360 ))"
  build="$(random_hex 4)"
  seed="$((16#$(random_hex 3)))"
  version="$(secure_random_int 1 5).$(secure_random_int 0 24).$(secure_random_int 0 40)"
  year="$(date +%Y)"
  brand_slug="$(printf '%s' "$brand" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+|-+$//g')"
  asset_dir="$(random_pick assets static res media dist public build cdn files)/$(random_hex 3)"

  # 1. Переносим CSS/JS/картинки в случайный каталог со случайными именами.
  # Список фиксируется заранее: переносимые файлы не должны попасть в обход повторно.
  local -a renames=() files=()
  local file rel ext new_rel
  mapfile -t files < <(find "$out" -type f | sort)
  for file in "${files[@]}"; do
    rel="${file#"${out}"/}"
    case "$rel" in
      index.html|404.html|robots.txt|favicon.svg|favicon.ico) continue ;;
    esac
    ext="${rel##*.}"
    new_rel="${asset_dir}/$(random_hex "$(secure_random_int 4 7)").${ext}"
    mkdir -p "${out}/${asset_dir}"
    mv "$file" "${out}/${new_rel}"
    renames+=("${rel}|${new_rel}")
  done
  find "$out" -mindepth 1 -type d -empty -delete 2>/dev/null || true

  # 2. sed-скрипт: пути ресурсов и плейсхолдеры.
  sed_script="$(mktemp)"
  local pair old new
  for pair in "${renames[@]}"; do
    old="${pair%%|*}"
    new="${pair#*|}"
    printf 's|/%s|/%s|g\n' "$(sed_escape_pattern "$old")" "$(sed_escape_replacement "$new")" >> "$sed_script"
  done
  {
    printf 's|__P__|%s|g\n' "$(sed_escape_replacement "$prefix")"
    printf 's|__BRAND__|%s|g\n' "$(sed_escape_replacement "$brand")"
    printf 's|__BRAND_SLUG__|%s|g\n' "$(sed_escape_replacement "$brand_slug")"
    printf 's|__DOMAIN__|%s|g\n' "$(sed_escape_replacement "$domain")"
    printf 's|__YEAR__|%s|g\n' "$year"
    printf 's|__HUE__|%s|g\n' "$hue"
    printf 's|__HUE2__|%s|g\n' "$hue2"
    printf 's|__BUILD__|%s|g\n' "$build"
    printf 's|__SEED__|%s|g\n' "$seed"
    printf 's|__VERSION__|%s|g\n' "$version"
  } >> "$sed_script"

  while IFS= read -r file; do
    is_text_asset "$file" || continue
    sed -i -f "$sed_script" "$file"
  done < <(find "$out" -type f)
  rm -f "$sed_script"

  # 3. Шум: build-метки, лишние CSS-правила, атрибуты, минификация HTML.
  while IFS= read -r file; do
    case "$file" in
      *.css)
        { printf '/*! %s v%s | %s */\n' "$brand_slug" "$version" "$build"; cat "$file"; css_noise "$prefix"; } > "${file}.tmp"
        mv "${file}.tmp" "$file"
        ;;
      *.js)
        local js_var
        js_var="_$(random_letters "$(secure_random_int 3 7)")"
        { printf '/*! %s %s */\n' "$build" "$(random_hex 6)"; cat "$file"
          printf ';(function(){var %s=%s;return %s})();\n' "$js_var" "$(secure_random_int 1 99999)" "$js_var"
        } > "${file}.tmp"
        mv "${file}.tmp" "$file"
        ;;
      *.html)
        local attr
        attr="data-$(random_letters "$(secure_random_int 1 3)")-$(random_hex 2)"
        sed -i -E "0,/<body([ >])/s//<body ${attr}=\"$(random_hex 3)\"\1/" "$file"
        sed -i -E "0,/<head>/s//<head>\n<!-- build ${build}-$(random_hex 2) -->/" "$file"
        # Минификация отступов меняет размер и хеш; <pre> не трогаем.
        if (( $(secure_random_int 0 1) == 1 )) && ! grep -q '<pre' "$file"; then
          sed -i -E 's/^[[:space:]]+//' "$file"
        fi
        ;;
    esac
  done < <(find "$out" -type f)

  # 4. Обязательные служебные файлы.
  if [[ ! -f "${out}/favicon.svg" ]]; then
    local initial="${brand:0:1}"
    cat > "${out}/favicon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="$(secure_random_int 10 20)" fill="hsl(${hue} 62% 46%)"/><text x="32" y="43" font-family="Arial,Helvetica,sans-serif" font-size="30" font-weight="700" fill="#fff" text-anchor="middle">${initial^^}</text></svg>
EOF
  fi
  [[ -f "${out}/robots.txt" ]] || printf 'User-agent: *\nDisallow: /\n' > "${out}/robots.txt"
  if [[ ! -f "${out}/404.html" ]]; then
    cat > "${out}/404.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>404 — ${brand}</title><link rel="icon" href="/favicon.svg"></head><body><h1>404</h1><p>The requested resource is not available.</p><p><a href="/">${brand}</a></p></body></html>
EOF
  fi

  if grep -rEl '__[A-Z0-9_]+__' "$out" >/dev/null 2>&1; then
    warn "В шаблоне остались незаменённые плейсхолдеры: $(grep -rEo '__[A-Z0-9_]+__' "$out" | sort -u | head -n 5 | tr '\n' ' ')"
  fi

  find "$out" -type d -exec chmod 755 {} +
  find "$out" -type f -exec chmod 644 {} +
}

select_template() {
  local dir="$1" choice index name
  local -a names=()
  mapfile -t names < <(templates_names "$dir")
  ((${#names[@]} > 0)) || die "Каталог шаблонов пуст: ${dir}"

  echo >&2
  echo -e "${C_BOLD}Шаблоны сайтов-заглушек${C_RESET}" >&2
  echo "Скриншоты: https://github.com/${RNM_REPO}/tree/${RNM_REF}/templates/sites" >&2
  echo >&2
  for index in "${!names[@]}"; do
    printf '%3d. %-17s %s\n' "$((index + 1))" "${names[$index]}" "$(template_title "${dir}/${names[$index]}")" >&2
  done
  echo >&2
  echo "  r. Случайный шаблон" >&2
  echo >&2
  read -r -p "Выбор [r]: " choice
  choice="${choice:-r}"
  if [[ "$choice" == "r" || "$choice" == "R" ]]; then
    name="$(random_pick "${names[@]}")"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#names[@]})); then
    name="${names[$((choice - 1))]}"
  else
    die "Некорректный выбор."
  fi
  printf '%s' "$name"
}

prompt_brand() {
  local input default="${1:-}"
  read -r -p "Название бренда на сайте${default:+ [${default}]} (Enter = случайное, '-' = случайное каждый раз): " input
  if [[ "$input" == "-" ]]; then
    SERVICE_NAME=""
  elif [[ -n "$input" ]]; then
    validate_service_name "$input" || die "Название содержит неподдерживаемые символы."
    SERVICE_NAME="$input"
  elif [[ -n "$default" ]]; then
    SERVICE_NAME="$default"
  else
    SERVICE_NAME=""
  fi
}

# Разворачивает шаблон в ${BASE_DIR}/html (inode каталога сохраняется — nginx
# видит новые файлы без пересоздания контейнера).
deploy_site() {
  local template="${1:-}" domain="${2:-$DOMAIN}"
  local dir brand tmp_out html_dir="${BASE_DIR}/html"
  validate_domain "$domain" || die "Для сайта нужен корректный домен."

  dir="$(templates_dir)" || die "Каталог шаблонов недоступен."
  if [[ -z "$template" ]]; then
    template="$(select_template "$dir")"
  fi
  [[ -f "${dir}/${template}/index.html" ]] || die "Шаблон не найден: ${template}"

  brand="${SERVICE_NAME:-$(random_brand)}"
  mkdir -p "$html_dir" "$BACKUP_DIR"
  tmp_out="$(mktemp -d "${BASE_DIR}/site.tmp.XXXXXX")"
  site_render_template "${dir}/${template}" "$tmp_out" "$brand" "$domain" || { rm -rf "$tmp_out"; die "Не удалось собрать сайт."; }

  if find "$html_dir" -mindepth 1 -print -quit | grep -q .; then
    tar -czf "${BACKUP_DIR}/html-$(date +%Y%m%d-%H%M%S).tar.gz" -C "$html_dir" . 2>/dev/null || true
    # Храним только 5 последних копий сайта.
    find "$BACKUP_DIR" -maxdepth 1 -name 'html-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | tail -n +6 | cut -d' ' -f2- | xargs -r rm -f
  fi

  find "$html_dir" -mindepth 1 -delete
  cp -a "${tmp_out}/." "$html_dir/"
  rm -rf "$tmp_out"
  chmod 755 "$html_dir"

  SITE_TEMPLATE="$template"
  ok "Сайт «${template}» развёрнут (бренд: ${brand}, отпечаток: $(find "$html_dir" -type f -exec sha256sum {} + | sort | sha256sum | cut -c1-12))."
  reload_selfsteal_nginx
}

# Совместимость: старые вызовы write_site_files DOMAIN SERVICE_NAME.
write_site_files() {
  local domain="$1" service_name="${2:-}"
  [[ -n "$service_name" && "$service_name" != "$domain" ]] && SERVICE_NAME="$service_name"
  deploy_site "${SITE_TEMPLATE:-}" "$domain"
}

site_menu() {
  while true; do
    clear || true
    load_state
    print_header
    echo -e "${C_BOLD}Сайт-заглушка Selfsteal${C_RESET}"
    echo
    echo "Текущий шаблон: ${SITE_TEMPLATE:-—}   Бренд: ${SERVICE_NAME:-случайный при каждом деплое}"
    echo
    echo "1. Выбрать другой шаблон и развернуть"
    echo "2. Перегенерировать текущий шаблон (новый отпечаток)"
    echo "3. Изменить название бренда"
    echo "4. Обновить каталог шаблонов из GitHub"
    echo "5. Откатить сайт на предыдущую копию"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action site_action_deploy ""; pause ;;
      2) run_action site_action_deploy "${SITE_TEMPLATE:-}"; pause ;;
      3) run_action site_action_brand; pause ;;
      4) run_action templates_fetch 1; pause ;;
      5) run_action site_restore_previous; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

site_action_deploy() {
  load_state
  [[ -n "$DOMAIN" ]] || die "Домен не настроен — сначала установи Selfsteal."
  deploy_site "$1" "$DOMAIN"
  save_state
}

site_action_brand() {
  load_state
  prompt_brand "$SERVICE_NAME"
  save_state
  [[ -n "$DOMAIN" ]] && deploy_site "${SITE_TEMPLATE:-}" "$DOMAIN"
  save_state
}

site_restore_previous() {
  local latest html_dir="${BASE_DIR}/html"
  latest="$(find "$BACKUP_DIR" -maxdepth 1 -name 'html-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"
  [[ -n "$latest" ]] || die "Нет сохранённых копий сайта."
  confirm "Восстановить ${latest}?" || return 0
  find "$html_dir" -mindepth 1 -delete
  tar -xzf "$latest" -C "$html_dir"
  rm -f "$latest"
  ok "Сайт восстановлен."
}
