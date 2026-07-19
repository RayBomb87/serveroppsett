#!/usr/bin/env bash
# serveroppsett — generisk bootstrap for ferske Linux-servere
set -euo pipefail

CONF=/etc/serveroppsett.conf
ADMIN_CONF=/etc/serveroppsett-admin.conf
APPS_CONF=/etc/serveroppsett-apps.conf
TTY=/dev/tty

msg()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m ✔\033[0m %s\n' "$*" >&2; }
skip() { printf '\033[1;33m ↷\033[0m %s (hopper over)\n' "$*" >&2; }
die()  { printf '\033[1;31mFEIL:\033[0m %s\n' "$*" >&2; exit 1; }

link() { # link "URL" -> klikkbar lenke på stdout (viser rå URL i terminaler uten støtte)
  printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$1"
}

ask() { # ask "Spørsmål" [default] -> svar på stdout
  local q=$1 def=${2:-} svar
  if [ -n "$def" ]; then
    read -rp "$q [$def]: " svar < "$TTY"; printf '%s' "${svar:-$def}"
  else
    while true; do
      read -rp "$q: " svar < "$TTY"
      [ -n "$svar" ] && { printf '%s' "$svar"; return; }
    done
  fi
}

ask_yesno() { # ask_yesno "Spørsmål" -> exit 0=ja 1=nei
  local svar
  read -rp "$1 [j/n]: " svar < "$TTY"
  case "$svar" in [jJyY]*) return 0 ;; *) return 1 ;; esac
}

ask_valid() { # ask_valid "Spørsmål" "regex" "feilhint" [default] -> svar (spør på nytt til gyldig)
  local q=$1 re=$2 hint=$3 def=${4:-} svar
  while true; do
    svar=$(ask "$q" "$def")
    [[ "$svar" =~ $re ]] && { printf '%s' "$svar"; return; }
    msg "Ugyldig verdi ($hint): «$svar» — prøv igjen."
  done
}

show_app_info() { # show_app_info <app> -> henter og viser fersk repo-info fra GitHub
  local app=$1 repo json desc stars
  repo=$("app_repo_$app" 2>/dev/null) || { msg "Ingen info-kilde registrert for $app."; return; }
  msg "Henter fersk info om $app fra GitHub ..."
  json=$(curl -fsSL "https://api.github.com/repos/$repo" 2>/dev/null) || { msg "Klarte ikke hente info (nettverk eller GitHub utilgjengelig)."; return; }
  desc=$(printf '%s' "$json" | grep -oP '"description":\s*"\K[^"]*' | head -1)
  stars=$(printf '%s' "$json" | grep -oP '"stargazers_count":\s*\K[0-9]+' | head -1)
  printf '\n' >&2
  printf '  %s\n' "${desc:-(ingen beskrivelse funnet)}" >&2
  [ -n "$stars" ] && printf '  \xE2\xAD\x90 %s stjerner på GitHub\n' "$stars" >&2
  printf '  %s\n' "$(link "https://github.com/$repo")" >&2
  printf '\n' >&2
}

ask_install_choice() { # ask_install_choice <app> -> exit 0=ja 1=nei (viser info og spør på nytt ved 'i')
  local app=$1 svar
  while true; do
    read -rp "Installere $app? [j/n/i=info]: " svar < "$TTY"
    case "$svar" in
      [jJyY]*) return 0 ;;
      [iI]*) show_app_info "$app" ;;
      *) return 1 ;;
    esac
  done
}

require_root() { [ "$(id -u)" -eq 0 ] || die "Kjør som root (eller med sudo)."; }

detect_os() {
  [ -r /etc/os-release ] || die "Fant ikke /etc/os-release — ukjent system."
  . /etc/os-release
  OS_ID=$ID
  if command -v apt-get >/dev/null; then PKG=apt
  elif command -v dnf >/dev/null;   then PKG=dnf
  else die "Støtter apt/dnf — fant ingen av dem (distro: $OS_ID)."; fi
  ok "System: $PRETTY_NAME (pakkehåndterer: $PKG)"
}

pkg_update() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q ;;
    dnf) dnf upgrade -y -q ;;
  esac
}

pkg_install() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" ;;
    dnf) dnf install -y -q "$@" ;;
  esac
}

step_system() {
  msg "Oppdaterer systemet"
  pkg_update
  ok "System oppdatert"
  msg "Sjekker basispakker"
  pkg_install sudo curl ca-certificates openssl openssh-server
  ok "sudo, curl, ca-certificates, openssl, openssh-server på plass"
}

install_docker_engine() {
  if command -v docker >/dev/null; then
    skip "Docker er installert ($(docker --version)) — holdes oppdatert automatisk via systemoppdateringen"
  else
    curl -fsSL https://get.docker.com | sh
    ok "Docker installert: $(docker --version)"
  fi
  if command -v systemctl >/dev/null; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1 || die "docker compose-plugin mangler etter installasjon."
  docker info >/dev/null 2>&1 || die "Docker-daemonen svarer ikke (docker info feilet)."
  ok "Compose: $(docker compose version --short)"
}

step_docker() {
  msg "Docker"
  if command -v docker >/dev/null; then
    install_docker_engine
    return
  fi
  if ask_yesno "Installere Docker og Docker Compose?"; then
    install_docker_engine
  else
    skip "Docker (valgt bort — installeres automatisk senere hvis en app krever det)"
  fi
}

ensure_docker() { # kalles av apper som krever docker, uansett tidligere svar
  if ! command -v docker >/dev/null; then
    msg "Denne appen krever Docker — installerer det nå"
    install_docker_engine
  fi
  if [ -n "${ADMIN_USER:-}" ] && getent group docker >/dev/null && ! id -nG "$ADMIN_USER" | grep -qw docker; then
    usermod -aG docker "$ADMIN_USER"
    ok "$ADMIN_USER lagt til docker-gruppen"
  fi
}

step_admin_user() {
  msg "Admin-bruker"
  local forrige=""
  if [ -f "$ADMIN_CONF" ]; then
    . "$ADMIN_CONF"
    forrige=${ADMIN_USER:-}
    [ -n "$forrige" ] && msg "Fant tidligere admin-bruker: $forrige (trykk Enter for å gjenbruke)"
  fi
  while true; do
    ADMIN_USER=$(ask_valid "Brukernavn for admin-brukeren" '^[a-z_][a-z0-9_-]*$' "små bokstaver/tall/_/-" "$forrige")
    [ "$ADMIN_USER" != root ] && break
    msg "Admin-brukeren kan ikke være root — herding stenger root-SSH. Velg et annet navn."
  done
  if id -u "$ADMIN_USER" >/dev/null 2>&1; then
    skip "Brukeren $ADMIN_USER finnes"
  else
    useradd -m -s /bin/bash "$ADMIN_USER"
    msg "Sett passord for $ADMIN_USER:"
    until passwd "$ADMIN_USER" < "$TTY"; do msg "Passord ikke satt — prøv igjen:"; done
    ok "Bruker $ADMIN_USER opprettet"
  fi
  local sudogrp=sudo
  getent group sudo >/dev/null || sudogrp=wheel
  usermod -aG "$sudogrp" "$ADMIN_USER"
  local grupper=$sudogrp
  if getent group docker >/dev/null; then
    usermod -aG docker "$ADMIN_USER"
    grupper="$sudogrp, docker"
  fi
  ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  printf 'ADMIN_USER=%s\n' "$ADMIN_USER" > "$ADMIN_CONF"
  ok "$ADMIN_USER er i gruppene: $grupper"
}

step_ssh_key() {
  msg "SSH-nøkkel for $ADMIN_USER"
  local keyfile=$ADMIN_HOME/.ssh/authorized_keys nokler
  if [ -s "$keyfile" ]; then
    local antall; antall=$(grep -c . "$keyfile")
    skip "Fant $antall SSH-nøkkel(er) i $keyfile fra før — spør ikke om flere"
    return
  fi
  if ask_yesno "Hente offentlige nøkler fra en GitHub-konto?"; then
    local ghuser; ghuser=$(ask "GitHub-brukernavn")
    nokler=$(curl -fsSL "https://github.com/$ghuser.keys") || die "Klarte ikke hente nøkler for $ghuser."
    [ -n "$nokler" ] || die "GitHub-kontoen $ghuser har ingen offentlige nøkler."
  else
    nokler=$(ask_valid "Lim inn offentlig nøkkel (ssh-ed25519 ...)" '^(ssh-ed25519 |ssh-rsa |ecdsa-sha2-|sk-ssh-|sk-ecdsa-)' "må starte med ssh-ed25519/ssh-rsa/...")
  fi
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
  touch "$keyfile"
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    case "$n" in
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*|sk-ssh-*|sk-ecdsa-*) ;;
      *) die "Ugyldig SSH-nøkkel (må starte med ssh-ed25519/ssh-rsa/...): «$n»" ;;
    esac
    grep -qxF "$n" "$keyfile" && skip "Nøkkel ligger der fra før" || { printf '%s\n' "$n" >> "$keyfile"; ok "Nøkkel lagt til"; }
  done <<< "$nokler"
  chown "$ADMIN_USER:$ADMIN_USER" "$keyfile" || die "chown av authorized_keys feilet."
  chmod 600 "$keyfile" || die "chmod av authorized_keys feilet."
}

step_ssh_hardening() {
  msg "SSH-herding"
  [ -s "$ADMIN_HOME/.ssh/authorized_keys" ] || die "Ingen nøkkel i authorized_keys — nekter å stenge passordinnlogging."
  [ -f /etc/ssh/sshd_config ] || die "Fant ikke /etc/ssh/sshd_config — er openssh-server installert?"
  local f=/etc/ssh/sshd_config.d/00-serveroppsett.conf
  if [ -f "$f" ]; then
    skip "Herding er alt konfigurert ($f)"
  else
    install -d -m 755 /etc/ssh/sshd_config.d
    local backup=""
    if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config; then
      backup=$(mktemp)
      cp /etc/ssh/sshd_config "$backup"
      local tmp; tmp=$(mktemp)
      printf 'Include /etc/ssh/sshd_config.d/*.conf\n' | cat - /etc/ssh/sshd_config > "$tmp"
      mv "$tmp" /etc/ssh/sshd_config
    fi
    printf 'PermitRootLogin no\nPasswordAuthentication no\n' > "$f"
    if ! sshd -t; then
      rm -f "$f"
      [ -n "$backup" ] && mv "$backup" /etc/ssh/sshd_config
      die "sshd-konfig feilet validering — endringen er rullet tilbake."
    fi
    [ -n "$backup" ] && rm -f "$backup"
    if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
      ok "Root-SSH og passordinnlogging er stengt (kun nøkkel nå)"
    else
      msg "ADVARSEL: fikk ikke lastet sshd på nytt automatisk — kjør 'systemctl reload sshd' manuelt; herdingen gjelder først etter reload."
    fi
  fi
  msg "VIKTIG: test i et NYTT vindu at 'ssh $ADMIN_USER@<ip>' virker før du logger ut!"
}

step_identity() {
  msg "Server-identitet"
  if [ -f "$CONF" ]; then
    . "$CONF"
    [ -n "${SERVERNAVN:-}" ] || die "Korrupt $CONF (mangler SERVERNAVN) — slett fila og kjør på nytt."
    skip "Identitet finnes: $SERVERNAVN"
    return
  fi
  local lok node vmid dom
  lok=$(ask_valid "Lokasjon (kort, f.eks. sted1)" '^[A-Za-z0-9-]+$' "kun bokstaver/tall/bindestrek")
  node=$(ask_valid "Proxmox-node (f.eks. prox1)" '^[A-Za-z0-9-]+$' "kun bokstaver/tall/bindestrek")
  vmid=$(ask_valid "VM/CT-id (f.eks. 101)" '^[0-9]+$' "kun tall")
  dom=$(ask_valid "Domene (f.eks. eksempel.no)" '^[A-Za-z0-9.-]+$' "kun bokstaver/tall/punktum/bindestrek")
  SERVERNAVN="$lok-$node-$vmid.$dom"
  printf 'LOKASJON=%s\nNODE=%s\nVMID=%s\nDOMENE=%s\nSERVERNAVN=%s\n' \
    "$lok" "$node" "$vmid" "$dom" "$SERVERNAVN" > "$CONF"
  ok "Identitet lagret i $CONF: $SERVERNAVN"
}

get_lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || hostname -I | awk '{print $1}'
}

APP_KATALOG="arcane dozzle"

step_apps() {
  msg "App-installasjon"
  local owner=$ADMIN_USER
  if [ -f "$APPS_CONF" ]; then
    . "$APPS_CONF"
    [ -n "${APPS_DIR:-}" ] || die "Korrupt $APPS_CONF (mangler APPS_DIR) — slett fila og kjør på nytt."
    owner=${APPS_OWNER:-$ADMIN_USER}
    if [ "$owner" != "$ADMIN_USER" ]; then
      msg "Apper ble opprinnelig satt opp for brukeren $owner — bruker fortsatt $APPS_DIR for å unngå duplikatinstallasjon."
    fi
  else
    APPS_DIR=$ADMIN_HOME/apps/dockerapps
    printf 'APPS_DIR=%s\nAPPS_OWNER=%s\n' "$APPS_DIR" "$ADMIN_USER" > "$APPS_CONF"
  fi
  install -d -o "$owner" -g "$owner" "$(dirname "$APPS_DIR")" "$APPS_DIR"
  local app
  for app in $APP_KATALOG; do
    if [ -f "$APPS_DIR/$app/compose.yml" ]; then
      skip "$app er alt satt opp i $APPS_DIR/$app — spør ikke på nytt"
    elif ask_install_choice "$app"; then
      "install_$app"
    fi
  done
}

app_port_arcane() { printf '3552'; }
app_repo_arcane() { printf 'getarcaneapp/arcane'; }

install_arcane() {
  local dir=$APPS_DIR/arcane
  if [ -f "$dir/compose.yml" ]; then skip "arcane er alt satt opp i $dir"; return; fi
  ensure_docker
  local uid gid app_url ip port
  uid=$(id -u "$ADMIN_USER"); gid=$(id -g "$ADMIN_USER")
  ip=$(get_lan_ip)
  port=$(app_port_arcane)
  if ask_yesno "Bruke DNS-navn ($SERVERNAVN) i APP_URL? (n = bruk IP)"; then
    app_url="http://arcane.$SERVERNAVN:$port"
  else
    app_url="http://$ip:$port"
  fi
  install -d -o "$ADMIN_USER" -g "$ADMIN_USER" "$dir"
  printf 'ENCRYPTION_KEY=%s\nJWT_SECRET=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > "$dir/.env"
  chmod 600 "$dir/.env"
  cat > "$dir/compose.yml" <<EOF
services:
  arcane:
    image: ghcr.io/getarcaneapp/manager:latest
    container_name: arcane
    ports:
      - $port:$port
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - arcane-data:/app/data
      - $APPS_DIR:/app/data/projects
    environment:
      - APP_URL=$app_url
      - PUID=$uid
      - PGID=$gid
      - ENCRYPTION_KEY=\${ENCRYPTION_KEY}
      - JWT_SECRET=\${JWT_SECRET}
    restart: unless-stopped

volumes:
  arcane-data:
EOF
  chown -R "$ADMIN_USER:$ADMIN_USER" "$dir"
  (cd "$dir" && docker compose up -d)
  ok "arcane installert og kjører"
}

app_port_dozzle() { printf '8080'; }
app_repo_dozzle() { printf 'amir20/dozzle'; }

install_dozzle() {
  local dir=$APPS_DIR/dozzle
  if [ -f "$dir/compose.yml" ]; then skip "dozzle er alt satt opp i $dir"; return; fi
  ensure_docker
  local port; port=$(app_port_dozzle)
  install -d -o "$ADMIN_USER" -g "$ADMIN_USER" "$dir"
  cat > "$dir/compose.yml" <<EOF
services:
  dozzle:
    image: amir20/dozzle:latest
    container_name: dozzle
    ports:
      - $port:8080
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped
EOF
  chown -R "$ADMIN_USER:$ADMIN_USER" "$dir"
  (cd "$dir" && docker compose up -d)
  ok "dozzle installert og kjører"
}

print_app_logins() {
  local app funnet=0
  for app in $APP_KATALOG; do
    [ -f "$APPS_DIR/$app/compose.yml" ] && { funnet=1; break; }
  done
  [ "$funnet" -eq 1 ] || return 0
  local ip port ip_url dns_url forste=1
  ip=$(get_lan_ip)
  msg "Innloggingslenker for installerte apper:"
  printf '\n' >&2
  for app in $APP_KATALOG; do
    if [ -f "$APPS_DIR/$app/compose.yml" ]; then
      [ "$forste" -eq 1 ] || printf -- '----------------------------------------\n' >&2
      forste=0
      port=$("app_port_$app")
      ip_url="http://$ip:$port"
      dns_url="http://$app.$SERVERNAVN:$port"
      printf '\033[1m%s\033[0m\n' "$app" >&2
      printf '  IP:  %s\n' "$(link "$ip_url")" >&2
      printf '  DNS: %s  (krever oppsatt navn)\n' "$(link "$dns_url")" >&2
    fi
  done
  printf '\n' >&2
}

main() {
  require_root
  detect_os
  step_system
  step_docker
  step_admin_user
  step_ssh_key
  step_ssh_hardening
  step_identity
  step_apps
  print_app_logins
  ok "Ferdig! Logg inn som $ADMIN_USER med SSH-nøkkel."
}
main "$@"
