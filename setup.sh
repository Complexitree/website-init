#!/usr/bin/env bash
set -euo pipefail

# =========================
# Complexitree Setup Script
# =========================

# --- Helpers ---
need() { command -v "$1" >/dev/null 2>&1; }
die()  { echo "ERROR: $*" >&2; exit 1; }
ask()  { local p="$1"; local v; read -r -p "$p" v; echo "$v"; }
ask_s(){ local p="$1"; local v; read -rs -p "$p" v; echo; echo "$v"; }
trim() { awk '{gsub(/^[ \t]+|[ \t]+$/,""); print}' <<<"$1"; }

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then
  if need sudo; then exec sudo -E bash "$0" "$@"; else die "Bitte als root ausführen oder sudo installieren."; fi
fi

echo "==> Willkommen! Dieses Skript richtet Docker, Caddy (HTTPS) und Watchtower (Auto-Update) ein."

# --- Fragen / Inputs ---
DEFAULT_IMAGE="docker.io/complexitree/website:master"
IMAGE=$(ask "Container-Image [${DEFAULT_IMAGE}]: "); IMAGE="${IMAGE:-$DEFAULT_IMAGE}"

DOMAINS_CSV=$(ask "Liste der Domains (Komma-getrennt, inkl. www): ")
DOMAINS_CSV="$(trim "$DOMAINS_CSV")"
[ -z "$DOMAINS_CSV" ] && die "Es wurde keine Domain angegeben."
# Array aus CSV bauen (Leerzeichen entfernen)
DOMAINS=()
IFS=',' read -r -a RAW <<< "$DOMAINS_CSV"
for d in "${RAW[@]}"; do
  d="$(trim "$d")"
  [ -n "$d" ] && DOMAINS+=("$d")
done
[ "${#DOMAINS[@]}" -lt 1 ] && die "Keine gültigen Domains erkannt."

PRIMARY_DOMAIN=$(ask "Primäre (kanonische) Domain (eine aus der Liste): ")
PRIMARY_DOMAIN="$(trim "$PRIMARY_DOMAIN")"
# Validierung: PRIMARY_DOMAIN muss in DOMAINS vorkommen
FOUND=0
for d in "${DOMAINS[@]}"; do
  [ "$d" = "$PRIMARY_DOMAIN" ] && FOUND=1 && break
done
[ "$FOUND" -eq 0 ] && die "Primäre Domain '$PRIMARY_DOMAIN' ist nicht in der Domain-Liste."

LE_EMAIL=$(ask "E-Mail für Let's Encrypt (empfohlen, leer lassen für keine): ")
LE_EMAIL="$(trim "$LE_EMAIL")"

DOCKERHUB_USERNAME=$(ask "Docker Hub Benutzername: ")
[ -z "$DOCKERHUB_USERNAME" ] && die "Docker Hub Benutzername fehlt."
DOCKERHUB_TOKEN=$(ask "Docker Hub Access Token: ")
[ -z "$DOCKERHUB_TOKEN" ] && die "Docker Hub Token fehlt."

INSTALLER_ACCESS_GRANT=$(ask "INSTALLER_ACCESS_GRANT: ")
[ -z "$INSTALLER_ACCESS_GRANT" ] && die "INSTALLER_ACCESS_GRANT fehlt."

USE_UFW=$(ask "UFW-Firewall konfigurieren und Ports 22/80/443 erlauben? [y/N]: ")
USE_UFW="${USE_UFW,,}"

APP_DIR="/opt/complexitree"
mkdir -p "$APP_DIR"

echo "==> Systempakete installieren (Ubuntu/Debian erkannt)…"
if need apt; then
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y ca-certificates curl gnupg wget
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  die "Dieses Skript unterstützt aktuell apt-basierte Systeme (Ubuntu/Debian)."
fi

if [[ "$USE_UFW" == "y" || "$USE_UFW" == "yes" ]]; then
  echo "==> UFW konfigurieren…"
  apt install -y ufw
  ufw allow 22/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw --force enable || true
fi

echo "==> Docker-Login (privates Image)…"
echo "$DOCKERHUB_TOKEN" | docker login docker.io -u "$DOCKERHUB_USERNAME" --password-stdin

echo "==> Compose-Dateien schreiben…"
cd "$APP_DIR"

# .env
cat > .env <<EOF
# automatisch erstellt
IMAGE=$IMAGE
INSTALLER_ACCESS_GRANT=$INSTALLER_ACCESS_GRANT
PRIMARY_DOMAIN=$PRIMARY_DOMAIN
EOF

# docker-compose.yml
cat > docker-compose.yml <<'YAML'
services:
  app:
    image: ${IMAGE}
    container_name: complexitree_app
    restart: unless-stopped
    environment:
      INSTALLER_ACCESS_GRANT: ${INSTALLER_ACCESS_GRANT}
      ASPNETCORE_URLS: http://0.0.0.0:5000
    expose:
      - "5000"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:5000/health"]
      interval: 30s
      timeout: 5s
      retries: 5

  caddy:
    image: caddy:alpine
    container_name: complexitree_caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - app

  watchtower:
    image: containrrr/watchtower
    container_name: complexitree_watchtower
    restart: unless-stopped
    # Täglich um 03:00 Uhr: zieht Updates, räumt alte Images auf, kann zurückrollen, nutzt Registry-Auth
    command: --cleanup --include-restarting --rollback --stop-timeout 30s --schedule "0 3 * * *" --registry-auth
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /root/.docker/config.json:/config.json:ro

volumes:
  caddy_data:
  caddy_config:
YAML

# Caddyfile bauen:
# - Primäre Domain: echter Reverse Proxy
# - alle anderen Domains: Redirect -> primäre Domain
CADDY_TMP="$(mktemp)"
{
  # Redirect-Blöcke
  for d in "${DOMAINS[@]}"; do
    if [ "$d" != "$PRIMARY_DOMAIN" ]; then
      cat <<REDIR
$d {
    redir https://$PRIMARY_DOMAIN{uri}
}
REDIR
      echo
    fi
  done

  # Hauptblock mit optionaler LE-E-Mail
  echo -n "$PRIMARY_DOMAIN"
  echo " {"
  echo "    encode zstd gzip"
  echo "    reverse_proxy app:5000"
  if [ -n "$LE_EMAIL" ]; then
    cat <<TLS
    tls $LE_EMAIL
TLS
  else
    echo "    tls { }"
  fi
  echo "}"
} > "$CADDY_TMP"

mv "$CADDY_TMP" Caddyfile

echo "==> Container starten…"
docker compose pull
docker compose up -d

echo
echo "✅ Fertig!"
echo "   Primäre Domain: https://$PRIMARY_DOMAIN"
if [ "${#DOMAINS[@]}" -gt 1 ]; then
  echo "   Weitere Domains werden per 301 auf die primäre Domain umgeleitet:"
  for d in "${DOMAINS[@]}"; do
    [ "$d" != "$PRIMARY_DOMAIN" ] && echo "     - $d  ->  https://$PRIMARY_DOMAIN"
  done
fi
echo
echo "ℹ️  Logs ansehen:    cd $APP_DIR && docker compose logs -f caddy && docker compose logs -f app"
echo "ℹ️  Manuelles Update: cd $APP_DIR && docker compose pull && docker compose up -d"
echo
