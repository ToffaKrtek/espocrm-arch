#!/usr/bin/env bash
#
# run-espocrm.sh — интерактивный скрипт развёртывания EspoCRM в Docker.
#
#   1. Проверяет наличие и запуск Docker + Docker Compose.
#   2. Запрашивает адрес (URL) для CRM (по умолчанию localhost).
#   3. Спрашивает про выпуск SSL-сертификата Let's Encrypt.
#   4. Генерирует секреты (пароли БД и администратора) в .env.
#   5. Генерирует адаптированный docker-compose.yml (секреты — только через ${VAR}).
#   6. При выборе SSL поднимает nginx + certbot, выпускает сертификат, включает HTTPS.
#   7. Выводит всю необходимую информацию для входа и управления.
#
# Использование:  ./run-espocrm.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Вывод
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

info() { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}  ✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}  !${C_RESET} $*"; }
err()  { printf '%s\n' "${C_RED}  ✗${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Пути (всё рядом со скриптом)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
INFO_FILE="$SCRIPT_DIR/INSTALL-INFO.txt"
NGINX_DIR="$SCRIPT_DIR/nginx-conf"
CERTBOT_DIR="$SCRIPT_DIR/certbot"
NGINX_CONF="$NGINX_DIR/default.conf"

DB_SVC="espocrm-db"
APP_SVC="espocrm"
NGINX_SVC="espocrm-proxy"

# ---------------------------------------------------------------------------
# 1. Проверка окружения
# ---------------------------------------------------------------------------
check_prerequisites() {
  info "Проверка окружения..."

  command -v docker >/dev/null 2>&1 \
    || die "Docker не установлен: https://docs.docker.com/engine/install/"

  if docker info >/dev/null 2>&1; then
    ok "Docker-демон запущен"
  else
    die "Docker установлен, но демон недоступен. Проверьте 'docker info' и членство в группе 'docker'."
  fi

  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    die "Docker Compose не найден (ни 'docker compose', ни 'docker-compose')."
  fi
  ok "Docker Compose: $("${COMPOSE[@]}" version --short 2>/dev/null || echo ok)"

  command -v openssl >/dev/null 2>&1 \
    || die "openssl не найден — нужен для генерации секретов."
  ok "openssl доступен"
}

# ---------------------------------------------------------------------------
# Ввод
# ---------------------------------------------------------------------------
ask() {
  local prompt="$1" def="${2:-}" answer
  if [[ -n "$def" ]]; then
    read -r -p "$(printf '%s %s[%s]%s: ' "${C_BOLD}${prompt}${C_RESET}" "${C_YELLOW}" "$def" "${C_RESET}")" answer || true
    printf '%s' "${answer:-$def}"
  else
    read -r -p "$(printf '%s: ' "${C_BOLD}${prompt}${C_RESET}")" answer || true
    printf '%s' "$answer"
  fi
}

ask_yes_no() {
  local prompt="$1" def="${2:-Y}" answer
  while true; do
    answer="$(ask "$prompt (Y/n)" "$def")"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Ответьте 'y' или 'n'." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Разбор адреса: хост и порт из произвольного ввода
# ---------------------------------------------------------------------------
INPUT_URL=""
HOST=""
PORT=""
parse_address() {
  local raw="$INPUT_URL" tmp hostport
  tmp="${raw#*://}"
  case "$tmp" in */*) tmp="${tmp%%/*}";; esac
  hostport="$tmp"
  if [[ "$hostport" =~ ^\[.*\](:[0-9]+)?$ ]]; then
    HOST="${hostport%%]*}]"
    hostport="${hostport#"$HOST"}"
    PORT="${hostport#:}"
  elif [[ "$hostport" == *:* && "$hostport" != *:*:* ]]; then
    HOST="${hostport%%:*}"
    PORT="${hostport##*:}"
  else
    HOST="$hostport"
    PORT=""
  fi
  # Пустой ввод трактуем как localhost
  if [[ -z "$HOST" ]]; then HOST="localhost"; fi
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

host_unsuitable_for_le() {
  local h="$1"
  [[ "$h" == "localhost" || "$h" == "127.0.0.1" || "$h" == *".local" ]] && return 0
  is_ipv4 "$h" && return 0
  return 1
}

# ---------------------------------------------------------------------------
# 2-3. Интерактивные вопросы
# ---------------------------------------------------------------------------
SSL_ENABLED=false
SITE_URL=""
WEBSOCKET_URL=""
HTTP_PORT=""
EMAIL=""
DOMAIN=""

collect_settings() {
  echo
  info "Параметры развёртывания"
  INPUT_URL="$(ask "URL/адрес для CRM" "localhost")"
  parse_address

  if ask_yes_no "Настроить выпуск SSL (Let's Encrypt)?" "Y"; then
    SSL_ENABLED=true
  else
    SSL_ENABLED=false
  fi

  if [[ "$SSL_ENABLED" == true ]]; then
    DOMAIN="$HOST"
    EMAIL="$(ask "E-mail для Let's Encrypt (Enter — без e-mail)" "")"
    if host_unsuitable_for_le "$HOST"; then
      echo
      warn "Let's Encrypt НЕ выдаёт сертификаты для '${HOST}' (нужен публичный домен, доступный по 80/443)."
      warn "Выпуск сертификата, скорее всего, завершится ошибкой."
      if ! ask_yes_no "Всё равно продолжить выпуск SSL?" "n"; then
        SSL_ENABLED=false
      fi
    fi
  fi

  if [[ "$SSL_ENABLED" == true ]]; then
    SITE_URL="https://${HOST}"
    WEBSOCKET_URL="wss://${HOST}/websocket"
  else
    if [[ -n "$PORT" ]]; then
      HTTP_PORT="$PORT"
    elif [[ "$HOST" == "localhost" || "$HOST" == "127.0.0.1" ]]; then
      HTTP_PORT="8080"
    else
      HTTP_PORT="80"
    fi
    if [[ "$HTTP_PORT" == "80" ]]; then
      SITE_URL="http://${HOST}"
    else
      SITE_URL="http://${HOST}:${HTTP_PORT}"
    fi
    WEBSOCKET_URL="ws://${HOST}:8081"
  fi
}

# ---------------------------------------------------------------------------
# 4. Секреты -> .env (идемпотентно: существующие значения не трогаем)
# ---------------------------------------------------------------------------
gen_secret()   { openssl rand -hex 16; }
gen_password() { openssl rand -hex 12; }

read_env_var() {
  [[ -f "$ENV_FILE" ]] || return 0
  local line
  line="$(grep -E "^$1=" "$ENV_FILE" | tail -n1 || true)"
  printf '%s' "${line#*=}"
}

write_env_file() {
  local root db_pass admin_user admin_pass
  root="$(read_env_var MARIADB_ROOT_PASSWORD)";        [[ -z "$root" ]] && root="$(gen_secret)"
  db_pass="$(read_env_var MARIADB_PASSWORD)";          [[ -z "$db_pass" ]] && db_pass="$(gen_secret)"
  admin_user="$(read_env_var ESPOCRM_ADMIN_USERNAME)"; [[ -z "$admin_user" ]] && admin_user="admin"
  admin_pass="$(read_env_var ESPOCRM_ADMIN_PASSWORD)"; [[ -z "$admin_pass" ]] && admin_pass="$(gen_password)"

  umask 077
  {
    echo "# Автогенерировано run-espocrm.sh $(date -Is)"
    echo "# ВНИМАНИЕ: файл содержит секреты, не коммитить в git."
    echo "MARIADB_ROOT_PASSWORD=${root}"
    echo "MARIADB_DATABASE=espocrm"
    echo "MARIADB_USER=espocrm"
    echo "MARIADB_PASSWORD=${db_pass}"
    echo "ESPOCRM_ADMIN_USERNAME=${admin_user}"
    echo "ESPOCRM_ADMIN_PASSWORD=${admin_pass}"
    echo "ESPOCRM_SITE_URL=${SITE_URL}"
    echo "ESPOCRM_WEBSOCKET_URL=${WEBSOCKET_URL}"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  MARIADB_ROOT_PASSWORD="$root"
  MARIADB_PASSWORD="$db_pass"
  ESPOCRM_ADMIN_USERNAME="$admin_user"
  ESPOCRM_ADMIN_PASSWORD="$admin_pass"
  ok "Секреты сохранены в $(basename "$ENV_FILE") (права 600)"
}

# ---------------------------------------------------------------------------
# 5. Генерация docker-compose.yml
# ---------------------------------------------------------------------------
write_compose_file() {
  info "Генерация docker-compose.yml..."
  if [[ "$SSL_ENABLED" == true ]]; then
    write_compose_ssl
  else
    write_compose_plain
  fi
  ok "docker-compose.yml готов"
}

write_compose_plain() {
  cat > "$COMPOSE_FILE" <<EOF
# Сгенерировано run-espocrm.sh — секреты храните в .env, не здесь
services:

  ${DB_SVC}:
    image: mariadb:latest
    container_name: ${DB_SVC}
    environment:
      MARIADB_ROOT_PASSWORD: \${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: \${MARIADB_DATABASE}
      MARIADB_USER: \${MARIADB_USER}
      MARIADB_PASSWORD: \${MARIADB_PASSWORD}
    volumes:
      - espocrm-db:/var/lib/mysql
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      start_period: 10s
      timeout: 10s
      retries: 3

  ${APP_SVC}:
    image: espocrm/espocrm:latest
    container_name: ${APP_SVC}
    environment:
      ESPOCRM_DATABASE_HOST: ${DB_SVC}
      ESPOCRM_DATABASE_USER: \${MARIADB_USER}
      ESPOCRM_DATABASE_PASSWORD: \${MARIADB_PASSWORD}
      ESPOCRM_ADMIN_USERNAME: \${ESPOCRM_ADMIN_USERNAME}
      ESPOCRM_ADMIN_PASSWORD: \${ESPOCRM_ADMIN_PASSWORD}
      ESPOCRM_SITE_URL: "\${ESPOCRM_SITE_URL}"
    volumes:
      - espocrm-data:/var/www/html/data
      - espocrm-custom:/var/www/html/custom
      - espocrm-custom-client:/var/www/html/client/custom
    restart: unless-stopped
    depends_on:
      ${DB_SVC}:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "bin/command", "app-check"]
      start_period: 20s
      interval: 60s
      timeout: 20s
      retries: 3
    ports:
      - ${HTTP_PORT}:80

  espocrm-daemon:
    image: espocrm/espocrm:latest
    container_name: espocrm-daemon
    volumes_from:
      - ${APP_SVC}
    restart: unless-stopped
    entrypoint: docker-daemon.sh
    depends_on:
      ${APP_SVC}:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "bin/command", "app-check"]
      start_period: 20s
      interval: 180s
      timeout: 20s
      retries: 3

  espocrm-websocket:
    image: espocrm/espocrm:latest
    container_name: espocrm-websocket
    environment:
      ESPOCRM_CONFIG_USE_WEB_SOCKET: "true"
      ESPOCRM_CONFIG_WEB_SOCKET_URL: "\${ESPOCRM_WEBSOCKET_URL}"
      ESPOCRM_CONFIG_WEB_SOCKET_ZERO_M_Q_SUBSCRIBER_DSN: "tcp://*:7777"
      ESPOCRM_CONFIG_WEB_SOCKET_ZERO_M_Q_SUBMISSION_DSN: "tcp://espocrm-websocket:7777"
    volumes_from:
      - ${APP_SVC}
    restart: unless-stopped
    entrypoint: docker-websocket.sh
    depends_on:
      ${APP_SVC}:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "bin/command", "app-check"]
      start_period: 20s
      interval: 180s
      timeout: 20s
      retries: 3
    ports:
      - 8081:8080

volumes:
  espocrm-db:
  espocrm-data:
  espocrm-custom:
  espocrm-custom-client:
EOF
}

write_compose_ssl() {
  cat > "$COMPOSE_FILE" <<EOF
# Сгенерировано run-espocrm.sh (режим SSL) — секреты храните в .env, не здесь
services:

  ${DB_SVC}:
    image: mariadb:latest
    container_name: ${DB_SVC}
    environment:
      MARIADB_ROOT_PASSWORD: \${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: \${MARIADB_DATABASE}
      MARIADB_USER: \${MARIADB_USER}
      MARIADB_PASSWORD: \${MARIADB_PASSWORD}
    volumes:
      - espocrm-db:/var/lib/mysql
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      start_period: 10s
      timeout: 10s
      retries: 3

  ${APP_SVC}:
    image: espocrm/espocrm:latest
    container_name: ${APP_SVC}
    environment:
      ESPOCRM_DATABASE_HOST: ${DB_SVC}
      ESPOCRM_DATABASE_USER: \${MARIADB_USER}
      ESPOCRM_DATABASE_PASSWORD: \${MARIADB_PASSWORD}
      ESPOCRM_ADMIN_USERNAME: \${ESPOCRM_ADMIN_USERNAME}
      ESPOCRM_ADMIN_PASSWORD: \${ESPOCRM_ADMIN_PASSWORD}
      ESPOCRM_SITE_URL: "\${ESPOCRM_SITE_URL}"
    volumes:
      - espocrm-data:/var/www/html/data
      - espocrm-custom:/var/www/html/custom
      - espocrm-custom-client:/var/www/html/client/custom
    restart: unless-stopped
    depends_on:
      ${DB_SVC}:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "bin/command", "app-check"]
      start_period: 20s
      interval: 60s
      timeout: 20s
      retries: 3
    expose:
      - "80"

  espocrm-daemon:
    image: espocrm/espocrm:latest
    container_name: espocrm-daemon
    volumes_from:
      - ${APP_SVC}
    restart: unless-stopped
    entrypoint: docker-daemon.sh
    depends_on:
      ${APP_SVC}:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "bin/command", "app-check"]
      start_period: 20s
      interval: 180s
      timeout: 20s
      retries: 3

  espocrm-websocket:
    image: espocrm/espocrm:latest
    container_name: espocrm-websocket
    environment:
      ESPOCRM_CONFIG_USE_WEB_SOCKET: "true"
      ESPOCRM_CONFIG_WEB_SOCKET_URL: "\${ESPOCRM_WEBSOCKET_URL}"
      ESPOCRM_CONFIG_WEB_SOCKET_ZERO_M_Q_SUBSCRIBER_DSN: "tcp://*:7777"
      ESPOCRM_CONFIG_WEB_SOCKET_ZERO_M_Q_SUBMISSION_DSN: "tcp://espocrm-websocket:7777"
    volumes_from:
      - ${APP_SVC}
    restart: unless-stopped
    entrypoint: docker-websocket.sh
    depends_on:
      ${APP_SVC}:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "bin/command", "app-check"]
      start_period: 20s
      interval: 180s
      timeout: 20s
      retries: 3
    expose:
      - "8080"

  ${NGINX_SVC}:
    image: nginx:1.27-alpine
    container_name: ${NGINX_SVC}
    restart: unless-stopped
    depends_on:
      ${APP_SVC}:
        condition: service_healthy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${NGINX_DIR}:/etc/nginx/conf.d:ro
      - ${CERTBOT_DIR}/conf:/etc/letsencrypt:ro
      - ${CERTBOT_DIR}/www:/var/www/certbot:ro

  certbot:
    image: certbot/certbot:latest
    container_name: espocrm-certbot
    volumes:
      - ${CERTBOT_DIR}/conf:/etc/letsencrypt
      - ${CERTBOT_DIR}/www:/var/www/certbot
    entrypoint: ["/bin/sh", "-c", "trap exit TERM; while :; do certbot renew --webroot -w /var/www/certbot --quiet; sleep 12h; done"]

volumes:
  espocrm-db:
  espocrm-data:
  espocrm-custom:
  espocrm-custom-client:
EOF
}

# ---------------------------------------------------------------------------
# Конфиги nginx (bootstrap — HTTP для ACME; full — HTTP->HTTPS + TLS)
# ---------------------------------------------------------------------------
write_nginx_bootstrap() {
  mkdir -p "$NGINX_DIR"
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://${APP_SVC}:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 100m;
    }
}
EOF
}

write_nginx_full() {
  mkdir -p "$NGINX_DIR"
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 100m;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location /websocket {
        proxy_pass http://espocrm-websocket:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }

    location / {
        proxy_pass http://${APP_SVC}:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 600s;
    }
}
EOF
}

# ---------------------------------------------------------------------------
# Проверка занятости портов
# ---------------------------------------------------------------------------
port_in_use() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltn 2>/dev/null | grep -qE ":$1([^0-9]|$)"
}

check_ports() {
  local ports=() p
  if [[ "$SSL_ENABLED" == true ]]; then
    ports=(80 443)
  else
    ports=("$HTTP_PORT" 8081)
  fi
  for p in "${ports[@]}"; do
    if port_in_use "$p"; then
      warn "Порт ${p} уже занят другим процессом — запуск контейнеров может завершиться ошибкой."
    fi
  done
}

# ---------------------------------------------------------------------------
# Ожидание готовности сервиса
# ---------------------------------------------------------------------------
wait_healthy() {
  local svc="$1" timeout="${2:-300}" waited=0 cid state
  info "Ожидание готовности сервиса '${svc}' (до ${timeout}s)..."
  while (( waited < timeout )); do
    cid="$("${COMPOSE[@]}" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps -q "$svc" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo unknown)"
      case "$state" in
        healthy|running) ok "Сервис '${svc}': ${state}"; return 0 ;;
        exited|dead)     err "Сервис '${svc}' завершился (state=${state})"; return 1 ;;
      esac
    fi
    sleep 5; waited=$((waited + 5))
  done
  warn "Таймаут ожидания '${svc}' (${timeout}s). Проверьте 'docker compose ps' и логи."
  return 0
}

# ---------------------------------------------------------------------------
# Выпуск сертификата Let's Encrypt
# ---------------------------------------------------------------------------
issue_certificate() {
  info "Выпуск SSL-сертификата для '${DOMAIN}'..."
  mkdir -p "$CERTBOT_DIR/conf" "$CERTBOT_DIR/www"

  local email_args=(-n --agree-tos --keep-until-expiring)
  if [[ -n "$EMAIL" ]]; then
    email_args+=(--email "$EMAIL")
  else
    email_args+=(--register-unsafely-without-email)
  fi

  if "${COMPOSE[@]}" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" run --rm --no-deps certbot \
       certonly --webroot -w /var/www/certbot -d "$DOMAIN" "${email_args[@]}"; then
    ok "Сертификат получен"
    return 0
  else
    err "Не удалось выпустить сертификат для '${DOMAIN}'."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# .gitignore
# ---------------------------------------------------------------------------
write_gitignore() {
  cat > "$SCRIPT_DIR/.gitignore" <<'EOF'
.env
INSTALL-INFO.txt
certbot/
EOF
}

# ---------------------------------------------------------------------------
# 7. Итоговый вывод
# ---------------------------------------------------------------------------
print_summary() {
  local auth_note
  if [[ "$SSL_ENABLED" == true ]]; then
    auth_note="SSL: ВКЛ (Let's Encrypt, ${DOMAIN}); продление автоматическое (certbot, каждые 12ч)"
  else
    auth_note="SSL: выключен (только HTTP)"
  fi

  {
    echo "========================================================"
    echo " EspoCRM развёрнут"
    echo "========================================================"
    echo " Дата:      $(date -Is)"
    echo
    echo " Доступ:"
    echo "   URL:            ${SITE_URL}"
    echo "   WebSocket:      ${WEBSOCKET_URL}"
    echo "   ${auth_note}"
    echo
    echo " Вход в приложение:"
    echo "   Логин:          ${ESPOCRM_ADMIN_USERNAME}"
    echo "   Пароль:         ${ESPOCRM_ADMIN_PASSWORD}"
    echo
    echo " База данных (MariaDB):"
    echo "   Host (в сети):    ${DB_SVC}"
    echo "   Database:         espocrm"
    echo "   User:             espocrm"
    echo "   Password:         ${MARIADB_PASSWORD}"
    echo "   Root password:    ${MARIADB_ROOT_PASSWORD}"
    echo
    echo " Файлы:"
    echo "   Секреты:        ${ENV_FILE}"
    echo "   Compose:        ${COMPOSE_FILE}"
    if [[ "$SSL_ENABLED" == true ]]; then
      echo
      echo " SSL:"
      echo "   Конфиг nginx:   ${NGINX_CONF}"
      echo "   Сертификаты:    ${CERTBOT_DIR}/conf/live/${DOMAIN}/"
      echo "   Продление вручную:"
      echo "     docker compose run --rm --no-deps certbot renew --webroot -w /var/www/certbot"
    fi
    echo
    echo " Управление:"
    echo "   Статус:      docker compose ps"
    echo "   Логи:        docker compose logs -f ${APP_SVC}"
    echo "   Остановить:  docker compose down"
    echo "   Перезапуск:  docker compose restart"
    echo "========================================================"
  } | tee "$INFO_FILE"
  chmod 600 "$INFO_FILE"
}

# ---------------------------------------------------------------------------
# Основная последовательность
# ---------------------------------------------------------------------------
main() {
  printf '%s\n' "${C_BOLD}Установка EspoCRM в Docker${C_RESET}"
  check_prerequisites
  collect_settings
  write_env_file
  write_compose_file
  write_gitignore
  check_ports

  if [[ "$SSL_ENABLED" == true ]]; then
    mkdir -p "$CERTBOT_DIR/conf" "$CERTBOT_DIR/www"
    write_nginx_bootstrap

    info "Запуск контейнеров (nginx временно на HTTP для выпуска сертификата)..."
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
    wait_healthy "$APP_SVC" 300

    if issue_certificate; then
      info "Включение HTTPS (перезапись конфига nginx + перезагрузка)..."
      write_nginx_full
      "${COMPOSE[@]}" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" restart "$NGINX_SVC"
      ok "HTTPS включён"
    else
      warn "HTTPS НЕ включён — приложение доступно по HTTP (bootstrap-конфиг nginx)."
      warn "Повторите выпуск после исправления:"
      warn "  docker compose run --rm --no-deps certbot certonly --webroot -w /var/www/certbot -d ${DOMAIN}"
      warn "Затем перезапустите ${NGINX_SVC} с полным TLS-конфигом."
      SSL_ENABLED=false
    fi
  else
    info "Запуск контейнеров..."
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
    wait_healthy "$APP_SVC" 300
  fi

  echo
  print_summary
}

main "$@"
