#!/usr/bin/env bash
# serveroppsett — generisk bootstrap for ferske Linux-servere
set -euo pipefail

CONF=/etc/serveroppsett.conf
TTY=/dev/tty

msg()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✔\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m ↷\033[0m %s (hopper over)\n' "$*"; }
die()  { printf '\033[1;31mFEIL:\033[0m %s\n' "$*" >&2; exit 1; }

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
  pkg_install sudo curl ca-certificates openssl
  ok "sudo, curl, ca-certificates, openssl på plass"
}

step_docker() {
  msg "Docker"
  if command -v docker >/dev/null; then
    skip "Docker er installert ($(docker --version))"
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

step_admin_user() {
  msg "Admin-bruker"
  ADMIN_USER=$(ask "Brukernavn for admin-brukeren")
  if id -u "$ADMIN_USER" >/dev/null 2>&1; then
    skip "Brukeren $ADMIN_USER finnes"
  else
    useradd -m -s /bin/bash "$ADMIN_USER"
    msg "Sett passord for $ADMIN_USER:"
    passwd "$ADMIN_USER" < "$TTY"
    ok "Bruker $ADMIN_USER opprettet"
  fi
  local sudogrp=sudo
  getent group sudo >/dev/null || sudogrp=wheel
  usermod -aG "$sudogrp" "$ADMIN_USER"
  getent group docker >/dev/null && usermod -aG docker "$ADMIN_USER"
  ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  ok "$ADMIN_USER er i gruppene: $sudogrp, docker"
}

step_ssh_key() {
  msg "SSH-nøkkel for $ADMIN_USER"
  local keyfile=$ADMIN_HOME/.ssh/authorized_keys nokler
  if ask_yesno "Hente offentlige nøkler fra en GitHub-konto?"; then
    local ghuser; ghuser=$(ask "GitHub-brukernavn")
    nokler=$(curl -fsSL "https://github.com/$ghuser.keys") || die "Klarte ikke hente nøkler for $ghuser."
    [ -n "$nokler" ] || die "GitHub-kontoen $ghuser har ingen offentlige nøkler."
  else
    nokler=$(ask "Lim inn offentlig nøkkel (ssh-ed25519 ...)")
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

main() {
  require_root
  detect_os
  step_system
  step_docker
  step_admin_user
  step_ssh_key
}
main "$@"
