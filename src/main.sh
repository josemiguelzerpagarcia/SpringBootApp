#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Colores / mensajes
# -----------------------------
if [[ -t 1 ]]; then
  GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; BLUE="\033[0;34m"; CYAN="\033[0;36m"; RESET="\033[0m"
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; CYAN=""; RESET=""
fi
say()  { echo -e "${BLUE}==>${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
err()  { echo -e "${RED}[ERR]${RESET} $*" >&2; }
info() { echo -e "${CYAN}     $*${RESET}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "No existe el comando: $1"; exit 1; }; }

have_sudo() { command -v sudo >/dev/null 2>&1; }
require_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    have_sudo || { err "Necesitas privilegios de admin y no existe sudo."; exit 1; }
    sudo -v
  fi
}

# -----------------------------
# Root del proyecto
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
find_up() {
  local dir="$1"
  while :; do
    [[ -f "$dir/docker-compose.yml" ]] && { echo "$dir"; return 0; }
    [[ "$dir" == "/" ]] && break
    dir="$(cd "$dir/.." && pwd)"
  done
  return 1
}
ROOT_DIR="$(find_up "$SCRIPT_DIR" || true)"
[[ -n "${ROOT_DIR:-}" ]] || { err "No encuentro docker-compose.yml subiendo desde: $SCRIPT_DIR"; exit 1; }
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
cd_root() { cd "$ROOT_DIR"; }

# -----------------------------
# IP privada + URLs
# -----------------------------
get_private_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  if [[ -z "${ip:-}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' \
      | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | head -n1 || true)"
  fi
  if [[ -z "${ip:-}" ]] && command -v ifconfig >/dev/null 2>&1; then
    ip="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -n1 || true)"
  fi
  echo "${ip:-}"
}

print_access_urls() {
  local ip; ip="$(get_private_ip || true)"
  echo
  say "Accesos locales (esta máquina):"
  ok "  Frontend   → http://localhost:8081"
  ok "  Backend    → http://localhost:9091"
  ok "  Swagger UI → http://localhost:8083"
  ok "  MySQL      → localhost:3306"
  echo
  if [[ -n "${ip:-}" ]]; then
    say "Accesos desde otra máquina (LAN):"
    ok "  Frontend   → http://${ip}:8081"
    ok "  Backend    → http://${ip}:9091"
    ok "  Swagger UI → http://${ip}:8083"
    ok "  MySQL      → ${ip}:3306"
  else
    warn "No pude detectar IP privada. Prueba: hostname -I / ip a"
  fi
  echo
}

# -----------------------------
# Detectar distro (VM Debian/Ubuntu)
# -----------------------------
linux_id_like() { ( . /etc/os-release 2>/dev/null || true; echo "${ID_LIKE:-${ID:-}}"; ); }
linux_id()      { ( . /etc/os-release 2>/dev/null || true; echo "${ID:-}"; ); }

# -----------------------------
# Instalar Docker + Compose en VM
# -----------------------------
ensure_docker_installed() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker detectado."
    return 0
  fi
  [[ "$(uname -s)" == "Linux" ]] || { err "Instalación automática solo para Linux (VM)."; exit 1; }

  local like id
  like="$(linux_id_like)"; id="$(linux_id)"
  if ! echo "$like $id" | grep -qiE 'debian|ubuntu'; then
    err "No puedo instalar Docker automáticamente (ID=$id LIKE=$like)."
    exit 1
  fi

  require_sudo
  say "Instalando Docker..."
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release uidmap git

  set +e
  curl -fsSL https://get.docker.com | sudo sh
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    warn "get.docker.com falló. Intento docker.io..."
    sudo apt-get install -y docker.io
  fi

  sudo systemctl enable --now docker 2>/dev/null || true
  sudo usermod -aG docker "$USER" 2>/dev/null || true
  ok "Docker instalado."
  warn "Si sale 'permission denied': cierra sesión/entra o ejecuta: newgrp docker"
}

# Preferir Compose v2 si existe
detect_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "docker compose"; return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"; return 0
  fi
  return 1
}

ensure_compose_installed() {
  local c; c="$(detect_compose || true)"
  if [[ -n "${c:-}" ]]; then
    ok "Compose detectado: $c"
    return 0
  fi

  require_sudo
  say "Instalando Docker Compose..."
  # v2 plugin (preferido)
  sudo apt-get update -y
  sudo apt-get install -y docker-compose-plugin || true
  # v1 fallback
  sudo apt-get install -y docker-compose || true

  c="$(detect_compose || true)"
  [[ -n "${c:-}" ]] || { err "No se pudo instalar Docker Compose."; exit 1; }
  ok "Compose instalado/detectado: $c"
}

# -----------------------------
# Permisos Docker: arreglar "Permission denied" automáticamente
# -----------------------------
DOCKER_PREFIX=() # [] o ["sudo"]
ensure_docker_access() {
  # 1) ¿docker daemon responde?
  if docker info >/dev/null 2>&1; then
    DOCKER_PREFIX=()
    return 0
  fi

  # 2) Si falla, probamos con sudo (si existe)
  if have_sudo && sudo docker info >/dev/null 2>&1; then
    warn "Tu usuario no tiene permisos sobre Docker (docker.sock). Usaré sudo automáticamente."
    DOCKER_PREFIX=(sudo)

    # Intentar dejarlo bien para la próxima sesión
    if getent group docker >/dev/null 2>&1; then
      sudo usermod -aG docker "$USER" >/dev/null 2>&1 || true
    else
      sudo groupadd docker >/dev/null 2>&1 || true
      sudo usermod -aG docker "$USER" >/dev/null 2>&1 || true
    fi

    warn "Para NO usar sudo: ejecuta 'newgrp docker' o cierra sesión y entra de nuevo."
    return 0
  fi

  # 3) Si ni con sudo, el daemon puede estar parado
  if have_sudo; then
    warn "Docker no responde. Intento arrancar el servicio..."
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
    if sudo docker info >/dev/null 2>&1; then
      DOCKER_PREFIX=(sudo)
      warn "Docker arrancado. Seguiré usando sudo (por permisos)."
      warn "Para NO usar sudo: newgrp docker o reiniciar sesión."
      return 0
    fi
  fi

  err "No puedo acceder al daemon de Docker."
  err "Prueba manualmente:"
  err "  docker info"
  err "  sudo docker info"
  err "  sudo systemctl status docker"
  exit 1
}

# -----------------------------
# Compose v1: quitar name y ABSOLUTIZAR rutas
# -----------------------------
TMP_COMPOSE_FILE=""
cleanup_tmp_compose() { [[ -n "${TMP_COMPOSE_FILE:-}" && -f "$TMP_COMPOSE_FILE" ]] && rm -f "$TMP_COMPOSE_FILE" || true; }
trap cleanup_tmp_compose EXIT

PROJECT_NAME_DEFAULT="springbootapp"

runtime_compose_file() {
  local c; c="$(detect_compose || true)"
  [[ -n "${c:-}" ]] || { err "No hay Compose instalado."; exit 1; }

  if [[ "$c" == "docker-compose" ]]; then
    if [[ -z "${TMP_COMPOSE_FILE:-}" || ! -f "$TMP_COMPOSE_FILE" ]]; then
      TMP_COMPOSE_FILE="$(mktemp -t springbootapp-compose.XXXXXX.yml)"
      awk -v root="$ROOT_DIR" '
        BEGIN { removed_name=0 }
        $0 ~ /^name:[[:space:]]/ && removed_name==0 { removed_name=1; next }
        {
          line=$0
          if (line ~ /^[[:space:]]*context:[[:space:]]*\.\//) {
            sub(/context:[[:space:]]*\.\//, "context: " root "/", line)
          }
          if (line ~ /^[[:space:]]*-[[:space:]]*\.\//) {
            sub(/-[[:space:]]*\.\//, "- " root "/", line)
          }
          print line
        }
      ' "$COMPOSE_FILE" > "$TMP_COMPOSE_FILE"
      warn "docker-compose v1 detectado: usando compose temporal SIN 'name:' + rutas absolutas -> $TMP_COMPOSE_FILE"
    fi
    echo "$TMP_COMPOSE_FILE"
  else
    echo "$COMPOSE_FILE"
  fi
}

compose() {
  local c; c="$(detect_compose || true)"
  [[ -n "${c:-}" ]] || { err "No hay Compose instalado."; exit 1; }

  cd_root
  local file; file="$(runtime_compose_file)"

  if [[ "$c" == "docker-compose" ]]; then
    "${DOCKER_PREFIX[@]}" docker-compose -p "${COMPOSE_PROJECT_NAME:-$PROJECT_NAME_DEFAULT}" -f "$file" "$@"
  else
    # docker compose (v2)
    "${DOCKER_PREFIX[@]}" docker compose -f "$file" "$@"
  fi
}

# -----------------------------
# Backend (GitHub) + Dockerfile auto
# -----------------------------
BACKEND_REPO_URL="https://github.com/Sergiogp7/API_SEGURITY_EXAMPLE.git"
BACKEND_BRANCH="main"
BACKEND_DIR="$ROOT_DIR/src/Backend/API_SEGURITY_EXAMPLE"

ensure_backend_repo() {
  need_cmd git
  mkdir -p "$ROOT_DIR/src/Backend"

  say "Backend: asegurando repo en: $BACKEND_DIR"
  info "Repo : $BACKEND_REPO_URL"
  info "Rama : $BACKEND_BRANCH"

  if [[ -d "$BACKEND_DIR/.git" ]]; then
    say "Backend: actualizando..."
    (
      cd "$BACKEND_DIR"
      git remote set-url origin "$BACKEND_REPO_URL" 2>/dev/null || git remote add origin "$BACKEND_REPO_URL"
      git fetch --all --prune

      local stashed="0"
      if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        warn "Cambios locales detectados -> stash temporal..."
        git stash push -m "main.sh auto-stash" >/dev/null || true
        stashed="1"
      fi

      git checkout "$BACKEND_BRANCH" 2>/dev/null || git checkout -b "$BACKEND_BRANCH" "origin/$BACKEND_BRANCH"
      git pull --ff-only || warn "pull --ff-only no aplicable; revisa git status"

      if [[ "$stashed" == "1" ]]; then
        warn "Restaurando stash..."
        git stash pop >/dev/null 2>&1 || warn "stash pop con conflictos — revisa: git stash list"
      fi
    )
    ok "Backend actualizado."
    return 0
  fi

  if [[ -d "$BACKEND_DIR" ]] && [[ -n "$(ls -A "$BACKEND_DIR" 2>/dev/null || true)" ]]; then
    err "El directorio backend existe y no está vacío, pero no es repo git:"
    err "  $BACKEND_DIR"
    err "Muévelo/bórralo y reintenta."
    exit 1
  fi

  say "Backend: clonando..."
  rm -rf "$BACKEND_DIR" 2>/dev/null || true
  git clone --branch "$BACKEND_BRANCH" --single-branch "$BACKEND_REPO_URL" "$BACKEND_DIR"
  ok "Backend clonado."
}

check_backend_build_files() {
  if [[ ! -f "$BACKEND_DIR/pom.xml" ]] && [[ ! -f "$BACKEND_DIR/build.gradle" ]] && [[ ! -f "$BACKEND_DIR/build.gradle.kts" ]]; then
    err "El backend no parece Maven/Gradle (no veo pom.xml ni build.gradle) en: $BACKEND_DIR"
    ls -la "$BACKEND_DIR" || true
    exit 1
  fi
}

ensure_backend_dockerfile() {
  if [[ -f "$BACKEND_DIR/Dockerfile" ]]; then
    ok "Dockerfile del backend ya existe."
    return 0
  fi
  warn "No existe Dockerfile en el backend. Generando uno estándar..."
  cat > "$BACKEND_DIR/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q -DskipTests dependency:go-offline
COPY src/ src/
RUN mvn -q -DskipTests package

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
ENV SERVER_ADDRESS=0.0.0.0
EXPOSE 9091
ENTRYPOINT ["java","-jar","/app/app.jar"]
EOF
  ok "Dockerfile generado en: $BACKEND_DIR/Dockerfile"
}

# -----------------------------
# Comandos
# -----------------------------
cmd_setup() {
  say "Setup: instalando dependencias en VM"
  ensure_docker_installed
  ensure_compose_installed
  ensure_docker_access
  ok "Setup completado."
}

cmd_fetch_backend() {
  ensure_backend_repo
  check_backend_build_files
  ensure_backend_dockerfile
  ok "Backend listo."
}

cmd_up() {
  ensure_docker_installed
  ensure_compose_installed
  ensure_docker_access
  cmd_fetch_backend

  echo
  say "Levantando entorno con: $(detect_compose)"
  info "Backend    → http://localhost:9091"
  info "Frontend   → http://localhost:8081"
  info "Swagger UI → http://localhost:8083"
  info "MySQL      → localhost:3306"
  echo

  compose down --remove-orphans 2>/dev/null || true
  compose up -d --build

  ok "Entorno levantado."
  print_access_urls
}

cmd_down() {
  ensure_compose_installed
  ensure_docker_access
  say "Parando todo..."
  compose down --remove-orphans
  ok "Todo parado."
}

cmd_reset() {
  ensure_compose_installed
  ensure_docker_access
  warn "RESET: borra volumen MySQL (pierdes datos). ¿Continuar? [s/N]"
  read -r confirm
  [[ "${confirm,,}" == "s" ]] || { warn "Cancelado."; return 0; }

  compose down -v --remove-orphans
  compose up -d --build
  ok "Reset completo."
  print_access_urls
}

cmd_info() {
  ensure_docker_installed
  ensure_compose_installed
  ensure_docker_access
  say "Información:"
  info "docker:  $("${DOCKER_PREFIX[@]}" docker --version 2>/dev/null || echo '<no>')"
  info "compose: $(detect_compose)"
  print_access_urls
}

usage() {
  cat <<EOF
Uso:
  ./main.sh setup          Instala Docker + Compose (VM Debian/Ubuntu) si faltan
  ./main.sh fetch-backend  Clona/actualiza el backend rama ${BACKEND_BRANCH}
  ./main.sh up             Levanta todo y muestra URLs (localhost + IP privada)
  ./main.sh down           Para todo
  ./main.sh reset          Borra volúmenes (MySQL) y levanta de nuevo
  ./main.sh info           Versiones + URLs
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    setup) cmd_setup "$@" ;;
    fetch-backend) cmd_fetch_backend "$@" ;;
    up|up-all) cmd_up "$@" ;;
    down|down-all) cmd_down "$@" ;;
    reset) cmd_reset "$@" ;;
    info) cmd_info "$@" ;;
    ""|-h|--help|help) usage ;;
    *) err "Comando desconocido: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
