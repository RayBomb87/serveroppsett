#!/usr/bin/env bash
# serveroppsett — generisk bootstrap for ferske Linux-servere
set -euo pipefail

CONF=/etc/serveroppsett.conf
ADMIN_CONF=/etc/serveroppsett-admin.conf
APPS_CONF=/etc/serveroppsett-apps.conf
TTY=/dev/tty

# Unngå apt-listchanges/perl sine harmløse "Cannot set locale"-varsler på
# ferske maler uten genererte locales (kun C er alltid tilgjengelig).
export LC_ALL=C
export LANGUAGE=C
export APT_LISTCHANGES_FRONTEND=none

msg()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m ✔\033[0m %s\n' "$*" >&2; }
skip() { printf '\033[1;33m ↷\033[0m %s (hopper over)\n' "$*" >&2; }
die()  { printf '\033[1;31mFEIL:\033[0m %s\n' "$*" >&2; exit 1; }
sep()  { printf '\n----------------------------------------\n' >&2; }

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
      printf '\n' >&2
    done
  fi
}

ask_yesno() { # ask_yesno "Spørsmål" -> exit 0=ja 1=nei (spør på nytt til gyldig j/n)
  local svar
  while true; do
    read -rp "$1 [j/n]: " svar < "$TTY"
    case "$svar" in
      [jJyY]*) return 0 ;;
      [nN]*) return 1 ;;
      *) msg "Ugyldig svar: «$svar» — skriv j eller n." ;;
    esac
  done
}

ask_valid() { # ask_valid "Spørsmål" "regex" "feilhint" [default] -> svar (spør på nytt til gyldig)
  local q=$1 re=$2 hint=$3 def=${4:-} svar
  while true; do
    svar=$(ask "$q" "$def")
    [[ "$svar" =~ $re ]] && { printf '%s' "$svar"; return; }
    msg "Ugyldig verdi ($hint): «$svar» — prøv igjen."
  done
}

ask_secret() { # ask_secret "Spørsmål" -> svar på stdout, uten ekko, aldri skrevet til disk
  local svar lengde halvt
  read -rsp "$1: " svar < "$TTY"; printf '\n' >&2
  lengde=${#svar}
  if [ "$lengde" -eq 0 ]; then
    msg "Fikk ingen input (tom verdi)."
  else
    halvt=$((lengde/2))
    if [ $((lengde % 2)) -eq 0 ] && [ "${svar:0:halvt}" = "${svar:halvt}" ]; then
      msg "OBS: det du limte inn ligner to like halvdeler etter hverandre ($lengde tegn totalt) — vanlig tegn på at limingen skjedde to ganger. Sjekk om nøkkelen er dobbel."
    fi
    msg "Mottok $lengde tegn (starter «${svar:0:4}…», slutter «…${svar: -4}»)."
  fi
  printf '%s' "$svar"
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

is_pve_host() { command -v pveversion >/dev/null; }

# SYSTEM_KATALOG — handlinger på selve Proxmox-hosten, samme katalog-mønster
# som APP_KATALOG. handling_<navn>() gjør jobben, handling_navn_<navn>()
# returnerer visningsnavnet i menyen. Nye host-handlinger legges til her.
SYSTEM_KATALOG="ve-oppgradering gpu-drivere"

handling_navn_ve-oppgradering() { printf 'VE-oppgradering (med valgfri AI-vurdering)'; }
handling_navn_gpu-drivere()     { printf 'GPU-drivere'; }

handling_gpu-drivere() { skip "GPU-drivere er ikke bygget ennå — kommer i en senere oppdatering."; }

systemmeny() { # bygger nummerert liste fra SYSTEM_KATALOG + Avbryt, dispatcher til handling_<navn>
  local -a navn=()
  local n
  for n in $SYSTEM_KATALOG; do navn+=("$n"); done
  local antall avbryt_nr valg i
  antall=${#navn[@]}
  avbryt_nr=$((antall+1))
  while true; do
    i=1
    for n in "${navn[@]}"; do
      printf '  %d) %s\n' "$i" "$("handling_navn_$n")" >&2
      i=$((i+1))
    done
    printf '  %d) Avbryt\n' "$avbryt_nr" >&2
    read -rp "Valg [1-$avbryt_nr]: " valg < "$TTY"
    if [[ "$valg" =~ ^[0-9]+$ ]] && [ "$valg" -ge 1 ] && [ "$valg" -le "$antall" ]; then
      "handling_${navn[$((valg-1))]}"; return
    elif [ "$valg" = "$avbryt_nr" ]; then
      msg "Avbryter uten å gjøre endringer."; return
    else
      msg "Ugyldig valg: «$valg» — skriv et tall mellom 1 og $avbryt_nr."
    fi
  done
}

pve_menu() {
  sep
  msg "Proxmox-vert oppdaget"
  msg "Denne serveren er selve Proxmox-hosten, ikke en gjest."
  local valg
  while true; do
    printf '  1) Systemendringer på hosten (VE-oppgradering, GPU-drivere, m.m.)\n' >&2
    printf '  2) Opprette og sette opp en ny CT\n' >&2
    printf '  3) Avbryt\n' >&2
    read -rp "Valg [1/2/3]: " valg < "$TTY"
    case "$valg" in
      1) systemmeny; return ;;
      2) create_ct; return ;;
      3) msg "Avbryter uten å gjøre endringer."; return ;;
      *) msg "Ugyldig valg: «$valg» — skriv 1, 2 eller 3." ;;
    esac
  done
}

run_wizard() {
  local -a steps=("$@")
  local i=0
  while [ "$i" -ge 0 ] && [ "$i" -lt "${#steps[@]}" ]; do
    "${steps[$i]}"
    case $? in
      0) i=$((i+1)) ;;
      1) return 1 ;;
      2) i=$((i-1)) ;;
      *) return 1 ;;
    esac
  done
  [ "$i" -ge 0 ]
}

pick_from_list() { # pick_from_list "Spørsmål" item1 item2 ... -> valgt item på stdout, exit 2 ved tilbake
  local sporsmal=$1; shift
  local -a valg=("$@")
  [ "${#valg[@]}" -gt 0 ] || return 1
  if [ "${#valg[@]}" -eq 1 ]; then printf '%s' "${valg[0]}"; return 0; fi
  local i svar
  local forste_gang=1
  while true; do
    [ "$forste_gang" -eq 1 ] || printf '\n' >&2
    forste_gang=0
    printf '%s\n' "$sporsmal" >&2
    for i in "${!valg[@]}"; do printf '  %d) %s\n' "$((i+1))" "${valg[$i]}" >&2; done
    printf '  t) tilbake\n' >&2
    read -rp "Valg: " svar < "$TTY"
    case "$svar" in
      t|T) return 2 ;;
      ''|*[!0-9]*) msg "Ugyldig valg." ;;
      *) if [ "$svar" -ge 1 ] 2>/dev/null && [ "$svar" -le "${#valg[@]}" ]; then
           printf '%s' "${valg[$((svar-1))]}"; return 0
         else
           msg "Ugyldig valg."
         fi ;;
    esac
  done
}

ask_yesno_back() { # ask_yesno_back "Spørsmål" j|n -> 0=ja 1=nei 2=tilbake
  local sporsmal=$1 std=$2 svar hint
  hint=$( [ "$std" = j ] && printf 'J/n' || printf 'j/N' )
  while true; do
    read -rp "$sporsmal [$hint/t=tilbake]: " svar < "$TTY"
    svar=${svar:-$std}
    case "$svar" in
      [jJ]*) return 0 ;;
      [nN]*) return 1 ;;
      [tT]) return 2 ;;
      *) msg "Svar j, n eller t." ;;
    esac
  done
}

pick_storage() { # pick_storage <innholdstype> <spørsmål> -> lagrings-ID på stdout, exit 2 ved tilbake
  local content=$1 sporsmal=$2
  local -a lager
  mapfile -t lager < <(pvesm status --content "$content" --enabled 1 2>/dev/null | awk 'NR>1{print $1}')
  [ "${#lager[@]}" -gt 0 ] || die "Fant ingen lagringsplass med innholdstype «$content» på denne Proxmox-hosten."
  pick_from_list "$sporsmal" "${lager[@]}"
}

step_ct_template() {
  sep
  msg "CT-mal"
  while true; do
    local lager
    lager=$(pick_storage vztmpl "Hvilken lagringsplass skal sjekkes for CT-maler?")
    [ $? -eq 2 ] && return 2
    CT_TEMPLATE_STORAGE=$lager
    printf '\n' >&2
    while true; do
      local -a maler
      mapfile -t maler < <(pvesm list "$CT_TEMPLATE_STORAGE" --content vztmpl | awk 'NR>1{print $1}')
      local valgt
      if [ "${#maler[@]}" -eq 0 ]; then
        msg "Ingen maler installert på $CT_TEMPLATE_STORAGE ennå."
        ask_yesno_back "Laste ned en ny mal fra Proxmox?" j
        case $? in
          2) continue 2 ;;
          1) continue 2 ;;
        esac
        valgt="Last ned ny mal fra Proxmox"
      else
        valgt=$(pick_from_list "Velg CT-mal på $CT_TEMPLATE_STORAGE:" "${maler[@]}" "Last ned ny mal fra Proxmox")
        case $? in
          2) continue 2 ;;
        esac
      fi
      if [ "$valgt" = "Last ned ny mal fra Proxmox" ]; then
        msg "Oppdaterer maloversikt fra Proxmox ..."
        pveam update >/dev/null
        local -a tilgjengelig
        mapfile -t tilgjengelig < <(pveam available --section system | awk '{print $2}')
        local nedlasting
        printf '\n' >&2
        nedlasting=$(pick_from_list "Velg mal å laste ned:" "${tilgjengelig[@]}")
        if [ $? -eq 2 ]; then continue; fi
        msg "Laster ned $nedlasting ..."
        pveam download "$CT_TEMPLATE_STORAGE" "$nedlasting" || die "Klarte ikke laste ned malen $nedlasting."
        continue
      fi
      CT_TEMPLATE=$valgt
      return 0
    done
  done
}

step_ct_vmid() {
  sep
  msg "VMID"
  local forslag; forslag=$(pvesh get /cluster/nextid)
  while true; do
    CT_VMID=$(ask "VMID for den nye CT-en" "$forslag")
    [ "$CT_VMID" = t ] && return 2
    [[ "$CT_VMID" =~ ^[0-9]+$ ]] || { msg "Må være tall."; continue; }
    pct status "$CT_VMID" >/dev/null 2>&1 && { msg "VMID $CT_VMID er alt i bruk — velg et annet."; continue; }
    return 0
  done
}

step_ct_hostname() {
  sep
  msg "Hostname"
  while true; do
    CT_HOSTNAME=$(ask "Hostname for CT-en (t=tilbake)")
    [ "$CT_HOSTNAME" = t ] && return 2
    [[ "$CT_HOSTNAME" =~ ^[A-Za-z0-9-]+$ ]] && return 0
    msg "Ugyldig hostname (kun bokstaver/tall/bindestrek): «$CT_HOSTNAME»"
  done
}

step_ct_storage() {
  sep
  msg "Lagring for CT-en"
  local svar; svar=$(pick_storage rootdir "Hvilken lagringsplass skal CT-en ligge på?")
  [ $? -eq 2 ] && return 2
  CT_STORAGE=$svar
  return 0
}

step_ct_resources() {
  sep
  msg "Ressurser (Enter = standardverdi i klammer)"
  local -a felt=(CT_CORES CT_MEMORY CT_SWAP CT_DISK)
  local -a etikett=("Antall CPU-kjerner" "RAM i MB" "Swap i MB" "Disk i GB")
  local -a std=(1 512 512 8)
  local i=0 svar
  while [ "$i" -ge 0 ] && [ "$i" -lt 4 ]; do
    [ "$i" -eq 0 ] || printf '\n' >&2
    svar=$(ask "${etikett[$i]} (t=tilbake)" "${std[$i]}")
    if [ "$svar" = t ]; then
      i=$((i-1))
      continue
    fi
    printf -v "${felt[$i]}" '%s' "$svar"
    i=$((i+1))
  done
  [ "$i" -ge 0 ] || return 2
  return 0
}

step_ct_sikkerhet() {
  sep
  msg "Sikkerhet"
  while true; do
    ask_yesno_back "Opprette som unprivileged container? (anbefalt)" j
    case $? in
      2) return 2 ;;
      0) CT_UNPRIVILEGED=1 ;;
      1) CT_UNPRIVILEGED=0 ;;
    esac
    printf '\n' >&2
    ask_yesno_back "Sette root-passord på CT-en?" n
    case $? in
      2) continue ;;
      0) CT_SET_ROOTPW=1; return 0 ;;
      1) CT_SET_ROOTPW=0; return 0 ;;
    esac
  done
}

step_ct_network() {
  sep
  msg "Nettverk"
  local -a broer
  mapfile -t broer < <(ip -o link show type bridge | awk -F': ' '{print $2}')
  [ "${#broer[@]}" -gt 0 ] || die "Fant ingen nettverksbro på denne Proxmox-hosten."
  while true; do
    CT_BRIDGE=$(pick_from_list "Velg nettverksbro:" "${broer[@]}")
    [ $? -eq 2 ] && return 2
    printf '\n' >&2
    ask_yesno_back "Bruke DHCP?" j
    case $? in
      2) continue ;;
      0) CT_NET_MODE=dhcp; CT_STATIC_IP=""; CT_GATEWAY=""; return 0 ;;
      1)
        printf '\n' >&2
        CT_STATIC_IP=$(ask_valid "IP-adresse i CIDR-form (f.eks. 10.10.1.99/24)" '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "må være IP/prefiks")
        printf '\n' >&2
        CT_GATEWAY=$(ask_valid "Gateway" '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "må være en IPv4-adresse")
        CT_NET_MODE=static
        return 0
        ;;
    esac
  done
}

step_ct_bekreft() {
  sep
  msg "Oppsummering:"
  printf '  VMID:         %s\n' "$CT_VMID" >&2
  printf '  Hostname:     %s\n' "$CT_HOSTNAME" >&2
  printf '  Mal:          %s\n' "$CT_TEMPLATE" >&2
  printf '  Lagring:      %s\n' "$CT_STORAGE" >&2
  printf '  Ressurser:    %s kjerne(r), %s MB RAM, %s MB swap, %s GB disk\n' "$CT_CORES" "$CT_MEMORY" "$CT_SWAP" "$CT_DISK" >&2
  if [ "$CT_NET_MODE" = dhcp ]; then
    printf '  Nettverk:     %s, DHCP\n' "$CT_BRIDGE" >&2
  else
    printf '  Nettverk:     %s, %s (gw %s)\n' "$CT_BRIDGE" "$CT_STATIC_IP" "$CT_GATEWAY" >&2
  fi
  printf '  Unprivileged: %s\n' "$([ "$CT_UNPRIVILEGED" -eq 1 ] && echo ja || echo nei)" >&2
  printf '  Root-passord: %s\n' "$([ "$CT_SET_ROOTPW" -eq 1 ] && echo "settes etter opprettelse" || echo "settes ikke")" >&2
  local svar
  while true; do
    printf '\n' >&2
    read -rp "Opprette CT-en med disse innstillingene? [j/t=tilbake/n=avbryt]: " svar < "$TTY"
    case "$svar" in
      [jJ]*) return 0 ;;
      [tT]) return 2 ;;
      [nN]*) return 1 ;;
      *) msg "Svar j, t eller n." ;;
    esac
  done
}

create_ct() {
  msg "CT-oppsett: trykk kun Enter for å godta standardverdien vist i klammer, f.eks. [512] — skriv «t» for å gå tilbake ett steg når som helst."
  # run_wizard MÅ kalles i en betingelse (if/&&/||) — stegene bruker
  # return 1/2 som normal navigasjon, og det krever at set -e er
  # slått av for hele kalltreet her.
  if ! run_wizard step_ct_template step_ct_vmid step_ct_hostname step_ct_storage \
                   step_ct_resources step_ct_sikkerhet step_ct_network step_ct_bekreft; then
    msg "CT-oppsett avbrutt."
    return
  fi

  local netstr
  if [ "$CT_NET_MODE" = dhcp ]; then
    netstr="name=eth0,bridge=$CT_BRIDGE,ip=dhcp"
  else
    netstr="name=eth0,bridge=$CT_BRIDGE,ip=$CT_STATIC_IP,gw=$CT_GATEWAY"
  fi

  msg "Oppretter CT $CT_VMID ..."
  pct create "$CT_VMID" "$CT_TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CORES" --memory "$CT_MEMORY" --swap "$CT_SWAP" \
    --rootfs "$CT_STORAGE:$CT_DISK" \
    --net0 "$netstr" \
    --unprivileged "$CT_UNPRIVILEGED" \
    --features nesting=1,keyctl=1 \
    --onboot 1 \
    || die "pct create feilet."
  ok "CT $CT_VMID opprettet"

  pct start "$CT_VMID" || die "pct start feilet."

  msg "Venter på at CT $CT_VMID er klar ..."
  local forsok=0
  until pct exec "$CT_VMID" -- true 2>/dev/null; do
    forsok=$((forsok+1))
    [ "$forsok" -ge 30 ] && die "CT $CT_VMID svarer ikke etter 30 sekunder — sjekk «pct status $CT_VMID» manuelt."
    sleep 1
  done
  ok "CT $CT_VMID er klar"

  msg "Venter på nettverk/DNS i CT $CT_VMID ..."
  forsok=0
  until pct exec "$CT_VMID" -- getent hosts raw.githubusercontent.com >/dev/null 2>&1; do
    forsok=$((forsok+1))
    [ "$forsok" -ge 30 ] && die "CT $CT_VMID fikk ikke nettverk/DNS etter 30 sekunder — sjekk nettverksoppsettet manuelt (f.eks. «pct exec $CT_VMID -- ip a»)."
    sleep 1
  done
  ok "Nettverk er oppe i CT $CT_VMID"

  if [ "$CT_SET_ROOTPW" -eq 1 ]; then
    msg "Sett root-passord for CT $CT_VMID:"
    until pct exec "$CT_VMID" -- passwd < "$TTY"; do msg "Passord ikke satt — prøv igjen:"; done
  fi

  msg "Bootstrapper CT $CT_VMID (kjører setup.sh inni containeren) ..."
  local raw_url=https://raw.githubusercontent.com/RayBomb87/serveroppsett/main/setup.sh
  local node_naam; node_naam=$(hostname)
  pct exec "$CT_VMID" -- bash -c "
    export SERVEROPPSETT_VMID_HINT='$CT_VMID'
    export SERVEROPPSETT_NODE_HINT='$node_naam'
    set -euo pipefail
    if ! command -v curl >/dev/null && ! command -v wget >/dev/null; then
      if command -v apt-get >/dev/null; then
        apt-get update -q || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl || true
      elif command -v dnf >/dev/null; then
        dnf install -y -q curl || true
      fi
    fi
    if command -v curl >/dev/null; then curl -fsSL '$raw_url' | bash
    elif command -v wget >/dev/null; then wget -qO- '$raw_url' | bash
    else echo 'Fant verken curl eller wget, og kunne ikke installere curl automatisk (ukjent pakkehåndterer i denne malen).' >&2; exit 1
    fi" \
    || die "Bootstrapping av CT $CT_VMID feilet — sjekk pct exec-loggen over."
  ok "CT $CT_VMID ($CT_HOSTNAME) er satt opp."
}

# --- Systemhandling: VE-oppgradering --------------------------------------

ensure_jq() { # trengs for å bygge/parse JSON trygt til/fra AI-API-ene
  command -v jq >/dev/null && return
  msg "jq mangler (trengs for AI-samtalen) — installerer ..."
  pkg_install jq || die "Klarte ikke installere jq automatisk."
  command -v jq >/dev/null || die "jq er installert, men finnes fortsatt ikke i PATH."
}

pve_gjeldende_major() { # -> nåværende PVE-hovedversjon på stdout
  pveversion | grep -oP 'pve-manager/\K[0-9]+' | head -1
}

finn_oppgraderingsverktoy() { # -> kommandonavn (f.eks. pve8to9) på stdout, tom streng hvis ingen kjent sti
  local n neste verktoy
  n=$(pve_gjeldende_major) || true
  [ -n "$n" ] || { printf ''; return; }
  neste=$((n+1))
  verktoy="pve${n}to${neste}"
  if command -v "$verktoy" >/dev/null; then printf '%s' "$verktoy"; return; fi
  # Sjekk-verktøyet ships med siste minor-release av NÅVÆRENDE hovedversjon
  # (f.eks. pve8to9 kom med 8.4.1) — ikke etter et repo-bytte. Oppdater først.
  msg "Sjekk-verktøyet $verktoy mangler — oppdaterer pakkelister for å hente det ..."
  apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade pve-manager >/dev/null 2>&1 || true
  command -v "$verktoy" >/dev/null && { printf '%s' "$verktoy"; return; }
  printf ''
}

# Kjent apt-kildekodenavn-overgang per PVE-hovedversjonshopp, "fra:til:gammelt:nytt".
# Kan ikke regnes ut generisk fra versjonsnummer — utvid denne når neste
# overgang (f.eks. 9→10) faktisk er kjent og dokumentert av Proxmox.
PVE_UPGRADE_CODENAMES="8:9:bookworm:trixie"

finn_kildekodenavn() { # finn_kildekodenavn <fra> <til> -> "gammelt nytt" på stdout, tom hvis ukjent
  local fra=$1 til=$2 par f t g n
  for par in $PVE_UPGRADE_CODENAMES; do
    IFS=: read -r f t g n <<< "$par"
    if [ "$f" = "$fra" ] && [ "$t" = "$til" ]; then printf '%s %s' "$g" "$n"; return; fi
  done
  printf ''
}

ai_leverandor_valg() { # -> "anthropic" | "openai" | "" (ingen) på stdout
  local svar
  while true; do
    printf '  1) Anthropic Claude\n' >&2
    printf '  2) OpenAI\n' >&2
    printf '  3) Ingen — vis kun rå rapport\n' >&2
    read -rp "Hvilken AI-tjeneste? [1/2/3]: " svar < "$TTY"
    case "$svar" in
      1) printf 'anthropic'; return ;;
      2) printf 'openai'; return ;;
      3) printf ''; return ;;
      *) msg "Ugyldig valg: «$svar» — skriv 1, 2 eller 3." ;;
    esac
  done
}

ai_kall() { # ai_kall <leverandor> <api_nokkel> <system> <meldinger_json> -> assistentens tekst på stdout
  local leverandor=$1 nokkel=$2 system=$3 meldinger=$4 body respons http_kode svar tekst
  case "$leverandor" in
    anthropic)
      body=$(jq -n --arg sys "$system" --argjson msgs "$meldinger" \
        '{model:"claude-sonnet-5", max_tokens:4096, thinking:{type:"disabled"}, system:$sys, messages:$msgs}')
      respons=$(curl -sSL -w '\n%{http_code}' https://api.anthropic.com/v1/messages \
        -H "content-type: application/json" \
        -H "x-api-key: $nokkel" \
        -H "anthropic-version: 2023-06-01" \
        -d "$body") || { msg "AI-kall feilet (nettverksfeil mot Anthropic — sjekk internettforbindelsen)."; return 1; }
      ;;
    openai)
      body=$(jq -n --arg sys "$system" --argjson msgs "$meldinger" \
        '{model:"gpt-4o", max_tokens:4096, messages: ([{role:"system", content:$sys}] + $msgs)}')
      respons=$(curl -sSL -w '\n%{http_code}' https://api.openai.com/v1/chat/completions \
        -H "content-type: application/json" \
        -H "Authorization: Bearer $nokkel" \
        -d "$body") || { msg "AI-kall feilet (nettverksfeil mot OpenAI — sjekk internettforbindelsen)."; return 1; }
      ;;
  esac
  http_kode=$(printf '%s' "$respons" | tail -1)
  svar=$(printf '%s' "$respons" | sed '$d')
  case "$http_kode" in
    200) ;;
    401) msg "AI-kall feilet: 401 Unauthorized — $leverandor avviste API-nøkkelen. Sjekk at den er riktig (og ikke limt inn dobbelt)."; return 1 ;;
    429) msg "AI-kall feilet: 429 — for mange forespørsler eller tomt kredittsaldo hos $leverandor."; return 1 ;;
    *) msg "AI-kall feilet: HTTP $http_kode fra $leverandor."; printf '%s\n' "$svar" >&2; return 1 ;;
  esac
  local stopp_arsak=""
  case "$leverandor" in
    anthropic)
      tekst=$(printf '%s' "$svar" | jq -r '[.content[]? | select(.type=="text") | .text] | join("\n")')
      stopp_arsak=$(printf '%s' "$svar" | jq -r '.stop_reason // empty')
      ;;
    openai)
      tekst=$(printf '%s' "$svar" | jq -r '.choices[0].message.content // empty')
      stopp_arsak=$(printf '%s' "$svar" | jq -r '.choices[0].finish_reason // empty')
      ;;
  esac
  if [ -z "$tekst" ]; then
    msg "Tomt eller uventet svar fra AI-tjenesten:"
    printf '%s\n' "$svar" >&2
    return 1
  fi
  if [ "$stopp_arsak" = "max_tokens" ] || [ "$stopp_arsak" = "length" ]; then
    msg "OBS: AI-svaret ble kuttet av fordi det nådde maks lengde — det er trolig ufullstendig (avsluttes midt i en setning)."
    tekst="$tekst

[MERK TIL AI-EN: svaret ditt over ble kuttet av pga. lengdegrense og er ufullstendig — fortsett der du slapp, eller oppsummer kort på nytt.]"
  fi
  printf '%s' "$tekst"
}

ai_samtale_loop() { # ai_samtale_loop <leverandor> <nokkel> <rapport> -> sluttvurdering-tekst på stdout (tom hvis AI-kall feilet)
  local leverandor=$1 nokkel=$2 rapport=$3
  local system meldinger_json runde tekst siste_tekst="" svar_bruker
  system="Du er en forsiktig, erfaren Proxmox-administrator som hjelper brukeren å vurdere risikoen ved en VE-oppgradering. Du får en rå pve*to*-rapport. Hvis du trenger mer informasjon fra selve serveren: IKKE be brukeren om å kjøre kommandoer manuelt selv — skriv i stedet kommandoen(e) i en \`\`\`bash-kodeblokk (bruk nøyaktig språktaggen «bash»). Skriptet viser kommandoen til brukeren, spør om lov, kjører den på serveren hvis godkjent, og sender deg output automatisk i neste runde. Foretrekk lesende/diagnostiske kommandoer. Undersøk tekniske fakta selv med \`\`\`bash-kommandoer (f.eks. lspci for maskinvare/GPU-modell, dpkg -l eller apt-cache policy for pakke-/driverversjoner) i stedet for å spørre brukeren om noe du kan sjekke direkte — bruk kun fri tekst til å spørre brukeren om egne preferanser, driftsbeslutninger, eller bekreftelse på risikofylte steg. Bruk apt-get (ikke apt) til pakkehåndtering (install/remove/purge/update/upgrade) — apt gir en skremmende «CLI-grensesnittet er ustabilt»-advarsel som apt-get ikke gjør, og resten av dette skriptet bruker apt-get konsekvent. Bruk «dpkg -l» i stedet for «apt list» for å liste installerte pakker. Still oppfølgingsspørsmål i fri tekst kun når du trenger en vurdering eller et valg fra brukeren selv, ikke maskindata. Når du er klar til å konkludere, AVSLUTT svaret ditt med en egen linje som starter nøyaktig med «SLUTTVURDERING: JA» eller «SLUTTVURDERING: NEI», etterfulgt av en kort begrunnelse. VIKTIG: bruk ALDRI denne markøren i samme svar som du ber om å få kjørt kommandoer eller stiller et åpent spørsmål til brukeren — SLUTTVURDERING betyr at du er helt ferdig og ikke trenger noe mer."
  meldinger_json=$(jq -n --arg r "$rapport" '[{role:"user", content: ("Her er rapporten:\n\n" + $r)}]')
  for runde in $(seq 1 12); do
    tekst=$(ai_kall "$leverandor" "$nokkel" "$system" "$meldinger_json") || { printf ''; return; }
    siste_tekst=$tekst

    # Pluk ut ```bash/sh/shell-kodeblokker AI-en ba om å få kjørt — vis, spør,
    # kjør på serveren ved godkjenning, og send output automatisk tilbake i
    # stedet for å tvinge brukeren til å kjøre kommandoer manuelt et annet sted.
    local fence_re='^```(bash|sh|shell)?[[:space:]]*$'
    local -a blokker=()
    local inn=0 blokk="" linje prosa=""
    while IFS= read -r linje; do
      if [[ "$linje" =~ $fence_re ]]; then
        if [ "$inn" -eq 1 ]; then blokker+=("$blokk"); blokk=""; inn=0; else inn=1; blokk=""; fi
      elif [ "$inn" -eq 1 ]; then
        blokk+="$linje"$'\n'
      else
        prosa+="$linje"$'\n'
      fi
    done <<< "$tekst"

    # En SLUTTVURDERING telles kun som endelig hvis AI-en IKKE samtidig ber om
    # å få kjørt kommandoer — noen ganger skriver den markøren for tidlig ved
    # siden av et oppfølgingsspørsmål, og da er den åpenbart ikke ferdig ennå.
    if [ "${#blokker[@]}" -eq 0 ] && printf '%s' "$tekst" | grep -q 'SLUTTVURDERING:'; then
      printf '%s' "$tekst"; return
    fi

    msg "AI-en spør (runde $runde/12):"
    printf '\n%s\n\n' "$tekst" >&2

    local kommando_resultat="" ut
    for blokk in "${blokker[@]}"; do
      [ -n "${blokk//[[:space:]]/}" ] || continue
      sep
      msg "AI-en foreslår å kjøre dette på serveren (samme rettigheter som dette skriptet, vanligvis root — les nøye):"
      printf '\n%s\n\n' "$blokk" >&2
      if ask_yesno "Kjøre denne kommandoen nå?"; then
        msg "Kjører — output vises live her. Spør kommandoen om noe (f.eks. apt sitt Y/n), svar direkte:"
        printf '\n' >&2
        ut=$(stdbuf -oL -eL bash -c "$blokk" < "$TTY" 2>&1 | tee "$TTY") || true
        printf '\n' >&2
        kommando_resultat="$kommando_resultat

\$ $blokk
--- output ---
$ut
"
      else
        kommando_resultat="$kommando_resultat

\$ $blokk
(brukeren valgte å ikke kjøre denne kommandoen)
"
      fi
    done

    if [ -n "$kommando_resultat" ]; then
      local tillegg
      if [ -n "${prosa//[[:space:]]/}" ]; then
        sep
        msg "Spørsmålet AI-en stilte (gjentatt, så du slipper å skrolle opp forbi kommando-output):"
        printf '\n%s\n' "$prosa" >&2
      fi
      read -rp "Stilte AI-en et spørsmål i teksten over? Skriv svaret ditt her (Enter for å gå videre uten): " tillegg < "$TTY"
      svar_bruker="Resultat av kommandoene AI-en ba om:${kommando_resultat}"
      [ -n "$tillegg" ] && svar_bruker="$svar_bruker"$'\n\nEkstra kommentar fra brukeren: '"$tillegg"
    else
      svar_bruker=$(ask "Ditt svar")
    fi

    meldinger_json=$(printf '%s' "$meldinger_json" | jq --arg a "$tekst" --arg u "$svar_bruker" \
      '. + [{role:"assistant", content:$a}, {role:"user", content:$u}]')
  done
  # 12 runder brukt uten SLUTTVURDERING — tving ett siste svar og bruk DET,
  # ikke et fall tilbake til kun rå rapport.
  msg "12 runder brukt uten en tydelig sluttvurdering — ber AI-en konkludere nå."
  meldinger_json=$(printf '%s' "$meldinger_json" | jq \
    '. + [{role:"user", content:"Du har ikke flere runder igjen. Gi din beste sluttvurdering NÅ, basert på alt vi har diskutert, med SLUTTVURDERING-linjen."}]')
  tekst=$(ai_kall "$leverandor" "$nokkel" "$system" "$meldinger_json") || { printf '%s' "$siste_tekst"; return; }
  printf '%s' "$tekst"
}

ai_konfigfil_policy() { # ai_konfigfil_policy <leverandor> <nokkel> <rapport> -> "confold"|"confnew"-linje fra AI-en, tom hvis feilet
  local leverandor=$1 nokkel=$2 rapport=$3 system meldinger_json tekst
  system="Du er en forsiktig Proxmox-administrator. Basert på rapporten under, anbefal ENTEN 'confold' (behold brukerens egne tilpasninger av config-filer) ELLER 'confnew' (bruk vedlikeholders nye versjon) som ÉN global policy for hele oppgraderingen. Svar med en linje som starter med 'ANBEFALING: confold' eller 'ANBEFALING: confnew', etterfulgt av en kort begrunnelse."
  meldinger_json=$(jq -n --arg r "$rapport" '[{role:"user", content: ("Rapport:\n\n" + $r)}]')
  tekst=$(ai_kall "$leverandor" "$nokkel" "$system" "$meldinger_json") || { printf ''; return; }
  msg "AI-ens anbefaling om config-fil-håndtering:"
  printf '\n%s\n\n' "$tekst" >&2
  printf '%s' "$tekst"
}

handling_ve-oppgradering() {
  sep
  msg "VE-oppgradering"
  local verktoy
  verktoy=$(finn_oppgraderingsverktoy)
  if [ -z "$verktoy" ]; then
    msg "Ingen kjent oppgraderingssti fra PVE $(pve_gjeldende_major) ennå — sjekk igjen senere."
    return
  fi
  msg "Kjører $verktoy --full ..."
  local rapport_fil rapport
  rapport_fil=$(mktemp)
  "$verktoy" --full > "$rapport_fil" 2>&1 || true
  rapport=$(cat "$rapport_fil"); rm -f "$rapport_fil"
  sep
  msg "Rå rapport fra $verktoy:"
  printf '\n%s\n\n' "$rapport" >&2

  local leverandor="" nokkel="" anbefaling=""
  if ask_yesno "Vil du ha AI-assistert risikovurdering av rapporten?"; then
    ensure_jq
    leverandor=$(ai_leverandor_valg)
    if [ -n "$leverandor" ]; then
      local nokkel_url=""
      case "$leverandor" in
        anthropic) nokkel_url="https://console.anthropic.com/settings/keys" ;;
        openai)    nokkel_url="https://platform.openai.com/api-keys" ;;
      esac
      msg "Lag/hent API-nøkkel her: $nokkel_url"
      nokkel=$(ask_secret "API-nøkkel for $leverandor (kun i minnet denne kjøringen, aldri lagret)")
      sep
      msg "Starter AI-samtale om oppgraderingen (maks 12 runder) ..."
      anbefaling=$(ai_samtale_loop "$leverandor" "$nokkel" "$rapport")
      if [ -n "$anbefaling" ]; then
        sep
        msg "AI-ens sluttvurdering:"
        printf '\n%s\n\n' "$anbefaling" >&2
      else
        msg "Fikk ikke noe brukbart svar fra AI-en — går videre med kun den rå rapporten."
      fi
    fi
  fi

  local n neste kodenavn gammelt_navn nytt_navn
  n=$(pve_gjeldende_major) || true
  neste=$((n+1))
  kodenavn=$(finn_kildekodenavn "$n" "$neste")
  if [ -z "$kodenavn" ]; then
    msg "Ingen kjent apt-kildekodenavn-overgang fra PVE $n til $neste registrert i skriptet ennå."
    msg "Sjekk Proxmox sin offisielle oppgraderingsguide manuelt, og legg ev. inn overgangen i PVE_UPGRADE_CODENAMES i setup.sh."
    return
  fi
  read -r gammelt_navn nytt_navn <<< "$kodenavn"

  local anbefalt_policy="" konfigpolicy policy_svar
  if [ -n "$leverandor" ]; then
    msg "Spør AI-en om anbefaling for config-fil-håndtering ..."
    anbefalt_policy=$(ai_konfigfil_policy "$leverandor" "$nokkel" "$rapport" | grep -oP "ANBEFALING:\s*\Kconf(old|new)" | head -1) || true
  fi
  sep
  msg "apt dist-upgrade kan støte på config-filer du har endret manuelt (f.eks. nettverksoppsett). Da må den vite på forhånd hvilken versjon den skal beholde — for ALLE slike filer under denne oppgraderingen:"
  msg "  confold = behold DINE tilpasninger av config-filer (tryggest for en produksjonshypervisor)"
  msg "  confnew = bruk vedlikeholders NYE versjon av config-filene"
  [ -n "$anbefalt_policy" ] && msg "AI-en anbefaler: $anbefalt_policy"
  while true; do
    read -rp "Velg policy [confold/confnew]: " policy_svar < "$TTY"
    case "$policy_svar" in
      confold|confnew) konfigpolicy=$policy_svar; break ;;
      *) msg "Ugyldig valg: «$policy_svar» — skriv confold eller confnew." ;;
    esac
  done

  sep
  msg "Klar til å oppgradere fra PVE $n til PVE $neste ($gammelt_navn → $nytt_navn)."
  msg "Dette bytter apt-kildene, kjører apt update, og deretter apt dist-upgrade interaktivt i forgrunnen."
  local bekreft
  bekreft=$(ask "Skriv nøyaktig «ja, kjør oppgraderingen» for å fortsette — alt annet avbryter uten endringer")
  if [ "$bekreft" != "ja, kjør oppgraderingen" ]; then
    msg "Avbryter — ingen endringer gjort."
    return
  fi

  msg "Bytter apt-kilder fra $gammelt_navn til $nytt_navn ..."
  grep -rl "$gammelt_navn" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | while read -r f; do
    sed -i "s/\b$gammelt_navn\b/$nytt_navn/g" "$f"
  done
  ok "Apt-kilder oppdatert."

  msg "Kjører apt-get update ..."
  apt-get update || die "apt-get update feilet — sjekk apt-kildene manuelt før du prøver igjen."

  msg "Kjører apt-get dist-upgrade (interaktivt — svar selv på eventuelle pakke-spørsmål) ..."
  local force_flag
  case "$konfigpolicy" in
    confold) force_flag='--force-confold' ;;
    confnew) force_flag='--force-confnew' ;;
  esac
  apt-get -o "Dpkg::Options::=$force_flag" dist-upgrade \
    || die "apt-get dist-upgrade feilet — systemet kan være i en delvis oppgradert tilstand. Undersøk manuelt før du fortsetter."
  ok "Oppgradering til PVE $neste fullført."

  if ask_yesno "Starte serveren på nytt nå?"; then
    msg "Starter på nytt ..."
    reboot
  else
    msg "Husk å starte serveren på nytt manuelt for at oppgraderingen skal fullføres helt."
  fi
}

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
  sep
  msg "Oppdaterer systemet"
  pkg_update
  ok "System oppdatert"
  msg "Sjekker basispakker"
  pkg_install sudo curl ca-certificates openssl openssh-server
  ok "sudo, curl, ca-certificates, openssl, openssh-server på plass"
}

step_locale() {
  sep
  msg "UTF-8-locale (æøå m.m. i f.eks. nano)"
  local f
  case "$PKG" in
    apt) f=/etc/default/locale ;;
    dnf) f=/etc/locale.conf ;;
  esac
  if [ -f "$f" ] && grep -qx 'LANG=C.UTF-8' "$f" 2>/dev/null; then
    skip "UTF-8-locale er alt satt (LANG=C.UTF-8 i $f)"
    return
  fi
  # C.UTF-8 er innebygd i glibc på moderne Debian/Ubuntu/Fedora — krever
  # ingen locale-gen/ekstra pakke, i motsetning til f.eks. en_US.UTF-8.
  if ! locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
    msg "ADVARSEL: fant ingen C.UTF-8-locale på dette systemet — æøå kan fortsatt feile i terminalprogrammer som nano."
    return
  fi
  printf 'LANG=C.UTF-8\nLC_ALL=C.UTF-8\n' > "$f"
  ok "LANG/LC_ALL satt til C.UTF-8 i $f — gjelder fra neste SSH-innlogging (logg ut/inn på nytt for å få effekten)"
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
  sep
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
  sep
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
  sep
  msg "SSH-nøkkel for $ADMIN_USER"
  local keyfile=$ADMIN_HOME/.ssh/authorized_keys nokler
  if [ -s "$keyfile" ]; then
    local antall; antall=$(grep -c . "$keyfile")
    skip "Fant $antall SSH-nøkkel(er) i $keyfile fra før — spør ikke om flere"
    return
  fi
  if ask_yesno "Hente offentlige nøkler fra en GitHub-konto?"; then
    printf '\n' >&2
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

port_ledig() { # port_ledig <port> -> exit 0 hvis ingen TCP-tjeneste lytter på porten
  if command -v ss >/dev/null 2>&1; then
    ! ss -Htln "sport = :$1" 2>/dev/null | grep -q .
  else
    ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

sporsmal_ny_ssh_port() { # sporsmal_ny_ssh_port <naavaerende_port> — setter globalene SSH_PORT_ENDRET (0/1) og SSH_NY_PORTLINJE ("" = 22).
  # NB: kalles direkte (IKKE via $(...)) — command substitution kjører i en
  # subshell der globale tildelinger ikke slipper ut til den kallende koden.
  local naa=$1 nyport
  SSH_PORT_ENDRET=0
  SSH_NY_PORTLINJE=""
  printf '\n' >&2
  ask_yesno "Vil du endre SSH-porten fra nåværende $naa?" || return 0
  printf '\n' >&2
  nyport=$(ask_valid "Ny SSH-port (1-65535)" '^[0-9]{1,5}$' "må være et tall")
  if [ "$nyport" -lt 1 ] || [ "$nyport" -gt 65535 ]; then
    msg "$nyport er utenfor gyldig portområde (1–65535) — ingen endring, beholder $naa."
    return 0
  fi
  if [ "$nyport" -eq "$naa" ]; then
    msg "$nyport er alt gjeldende port — ingen endring."
    return 0
  fi
  if ! port_ledig "$nyport"; then
    msg "ADVARSEL: port $nyport er allerede i bruk av noe annet på denne serveren — ingen endring, beholder $naa."
    return 0
  fi
  ok "Port $nyport er ledig — bytter SSH til denne porten."
  SSH_PORT_ENDRET=1
  [ "$nyport" -ne 22 ] && SSH_NY_PORTLINJE="Port $nyport"
  return 0
}

ssh_socket_enhet() { # -> navnet på aktiv ssh-socket-enhet på stdout (ssh.socket/sshd.socket), tom streng hvis systemet ikke bruker socket-aktivering
  local navn
  for navn in ssh.socket sshd.socket; do
    if systemctl list-unit-files "$navn" >/dev/null 2>&1 \
      && { systemctl is-active "$navn" >/dev/null 2>&1 || systemctl is-enabled "$navn" >/dev/null 2>&1; }; then
      printf '%s' "$navn"
      return 0
    fi
  done
  return 0
}

konfigurer_ssh_socket_port() { # konfigurer_ssh_socket_port <port> — oppdaterer ssh.socket/sshd.socket sin ListenStream
  # Moderne Debian/Ubuntu lar systemd binde SSH-porten via en egen .socket-enhet
  # og gir den videre til sshd — da blir "Port" i sshd_config IGNORERT helt.
  # RPM-baserte distroer (Fedora/RHEL/Rocky m.fl.) bruker normalt IKKE dette —
  # der er sshd_config sin Port-linje alt som trengs, og denne funksjonen er en no-op.
  local port=${1:-22} enhet
  enhet=$(ssh_socket_enhet)
  [ -n "$enhet" ] || return 0
  local d="/etc/systemd/system/$enhet.d"
  install -d -m 755 "$d"
  printf '[Socket]\nListenStream=\nListenStream=%s\n' "$port" > "$d/00-serveroppsett.conf"
  systemctl daemon-reload
  systemctl restart "$enhet" 2>/dev/null || true
}

skriv_ssh_herding_fil() { # skriv_ssh_herding_fil <portlinje> <f> — skriver, validerer, restarter sshd; ruller tilbake ved valideringsfeil
  local portlinje=$1 f=$2 forrige="" port=22
  [ -n "$portlinje" ] && port=${portlinje#Port }
  [ -f "$f" ] && forrige=$(cat "$f")
  {
    printf 'PermitRootLogin no\nPasswordAuthentication no\n'
    [ -n "$portlinje" ] && printf '%s\n' "$portlinje"
  } > "$f"
  if ! sshd -t; then
    if [ -n "$forrige" ]; then printf '%s\n' "$forrige" > "$f"; else rm -f "$f"; fi
    die "sshd-konfig feilet validering — endringen er rullet tilbake."
  fi
  konfigurer_ssh_socket_port "$port"
  if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
    ok "sshd restartet — ${portlinje:-standard SSH-port 22} er nå aktiv"
    msg "VIKTIG: test i et NYTT vindu at innlogging på den nye porten virker FØR du logger ut av denne økten!"
  else
    msg "ADVARSEL: fikk ikke restartet sshd automatisk — kjør 'systemctl restart sshd' manuelt for at portendringen skal tre i kraft."
  fi
}

step_ssh_hardening() {
  sep
  msg "SSH-herding"
  [ -s "$ADMIN_HOME/.ssh/authorized_keys" ] || die "Ingen nøkkel i authorized_keys — nekter å stenge passordinnlogging."
  [ -f /etc/ssh/sshd_config ] || die "Fant ikke /etc/ssh/sshd_config — er openssh-server installert?"
  local f=/etc/ssh/sshd_config.d/00-serveroppsett.conf
  if [ -f "$f" ]; then
    skip "Herding er alt konfigurert ($f)"
    local naa; naa=$(grep -oE '^Port [0-9]+' "$f" 2>/dev/null | awk '{print $2}') || true
    naa=${naa:-22}
    sporsmal_ny_ssh_port "$naa"
    [ "$SSH_PORT_ENDRET" -eq 1 ] && skriv_ssh_herding_fil "$SSH_NY_PORTLINJE" "$f"
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
    sporsmal_ny_ssh_port 22
    local portlinje=$SSH_NY_PORTLINJE
    local nyport=""; [ -n "$portlinje" ] && nyport=${portlinje#Port }
    {
      printf 'PermitRootLogin no\nPasswordAuthentication no\n'
      [ -n "$portlinje" ] && printf '%s\n' "$portlinje"
    } > "$f"
    if ! sshd -t; then
      rm -f "$f"
      [ -n "$backup" ] && mv "$backup" /etc/ssh/sshd_config
      die "sshd-konfig feilet validering — endringen er rullet tilbake."
    fi
    [ -n "$backup" ] && rm -f "$backup"
    konfigurer_ssh_socket_port "${nyport:-22}"
    if systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null; then
      if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        ok "Root-SSH og passordinnlogging er stengt (kun nøkkel nå)"
        [ -n "$portlinje" ] && msg "SSH lytter nå på port $nyport i stedet for 22 — husk å åpne denne porten i evt. brannmur/sikkerhetsgruppe før du logger ut."
      else
        msg "ADVARSEL: fikk ikke startet sshd på nytt automatisk — kjør 'systemctl restart sshd' manuelt; herdingen gjelder først etter restart."
      fi
    else
      msg "ADVARSEL: fikk ikke aktivert/startet SSH-tjenesten automatisk — kjør 'systemctl enable --now sshd' manuelt; herdingen gjelder først da."
    fi
  fi
  SSH_PORT=$(grep -oE '^Port [0-9]+' "$f" 2>/dev/null | awk '{print $2}') || true
  SSH_PORT=${SSH_PORT:-22}
  local ip; ip=$(get_lan_ip)
  local sshkomm="ssh $ADMIN_USER@$ip"
  [ "$SSH_PORT" != "22" ] && sshkomm="ssh -p $SSH_PORT $ADMIN_USER@$ip"
  msg "VIKTIG: test i et NYTT vindu at '$sshkomm' virker før du logger ut!"
}

step_identity() {
  sep
  msg "Server-identitet"
  if [ -f "$CONF" ]; then
    . "$CONF"
    [ -n "${SERVERNAVN:-}" ] || die "Korrupt $CONF (mangler SERVERNAVN) — slett fila og kjør på nytt."
    skip "Identitet finnes: $SERVERNAVN"
    return
  fi
  local lok node vmid dom
  lok=$(ask_valid "Lokasjon (kort, f.eks. sted1)" '^[A-Za-z0-9-]+$' "kun bokstaver/tall/bindestrek")
  printf '\n' >&2
  node=$(ask_valid "Proxmox-node (f.eks. prox1)" '^[A-Za-z0-9-]+$' "kun bokstaver/tall/bindestrek" "${SERVEROPPSETT_NODE_HINT:-}")
  printf '\n' >&2
  vmid=$(ask_valid "VM/CT-id (f.eks. 101)" '^[0-9]+$' "kun tall" "${SERVEROPPSETT_VMID_HINT:-}")
  printf '\n' >&2
  dom=$(ask_valid "Domene (f.eks. eksempel.no)" '^[A-Za-z0-9.-]+$' "kun bokstaver/tall/punktum/bindestrek")
  SERVERNAVN="$lok-$node-$vmid.$dom"
  printf 'LOKASJON=%s\nNODE=%s\nVMID=%s\nDOMENE=%s\nSERVERNAVN=%s\n' \
    "$lok" "$node" "$vmid" "$dom" "$SERVERNAVN" > "$CONF"
  ok "Identitet lagret i $CONF: $SERVERNAVN"
}

get_lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || hostname -I | awk '{print $1}'
}

pick_app_url() { # pick_app_url <app> -> hostname (uten protokoll/port) på stdout; lagrer egendefinert valg for gjenbruk i innloggingsoversikten
  local app=$1 dns_navn="$LOKASJON-$NODE-$VMID-$app.$DOMENE" ip valg
  ip=$(get_lan_ip)
  printf '\n' >&2
  printf 'Hvilken adresse skal %s bruke?\n' "$app" >&2
  printf '  1) DNS-navn (%s)\n' "$dns_navn" >&2
  printf '  2) IP (%s)\n' "$ip" >&2
  printf '  3) Egendefinert\n' >&2
  read -rp "Valg [1]: " valg < "$TTY"
  case "${valg:-1}" in
    2) printf '%s' "$ip" ;;
    3)
      printf '\n' >&2
      local egendef; egendef=$(ask_valid "Egendefinert adresse (uten http:// og port)" '^[A-Za-z0-9.-]+$' "kun bokstaver/tall/punktum/bindestrek")
      mkdir -p "$APPS_DIR/$app"
      printf '%s' "$egendef" > "$APPS_DIR/$app/.dns_navn"
      printf '%s' "$egendef"
      ;;
    *) printf '%s' "$dns_navn" ;;
  esac
}

APP_KATALOG="arcane dozzle airconnect-cast airconnect-upnp"

step_apps() {
  sep
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
  local app forste=1 nye_andre_apper=0
  for app in $APP_KATALOG; do
    if [ -f "$APPS_DIR/$app/compose.yml" ]; then
      skip "$app er alt satt opp i $APPS_DIR/$app — spør ikke på nytt"
    else
      [ "$forste" -eq 1 ] || printf '\n' >&2
      forste=0
      if ask_install_choice "$app"; then
        "install_$app"
        [ "$app" = "arcane" ] || nye_andre_apper=1
      fi
    fi
  done
  # Arcane skanner /app/data/projects kun ved oppstart (ingen pålitelig
  # live-overvåking av bind-mounten) — nyinstallerte apper i samme kjøring
  # vises derfor ikke som prosjekt før Arcane restartes.
  if [ "$nye_andre_apper" -eq 1 ] && [ -f "$APPS_DIR/arcane/compose.yml" ]; then
    (cd "$APPS_DIR/arcane" && docker compose restart) >/dev/null 2>&1 || true
    ok "Arcane restartet slik at nye apper vises i prosjektoversikten"
  fi
}

app_port_arcane() { printf '3552'; }
app_repo_arcane() { printf 'getarcaneapp/arcane'; }
app_login_arcane() { printf 'arcane / arcane-admin (du blir bedt om å bytte passord ved første innlogging)'; }

install_arcane() {
  local dir=$APPS_DIR/arcane
  if [ -f "$dir/compose.yml" ]; then skip "arcane er alt satt opp i $dir"; return; fi
  ensure_docker
  local uid gid app_url port hostname
  uid=$(id -u "$ADMIN_USER"); gid=$(id -g "$ADMIN_USER")
  port=$(app_port_arcane)
  hostname=$(pick_app_url arcane)
  app_url="http://$hostname:$port"
  install -d -o "$ADMIN_USER" -g "$ADMIN_USER" "$dir"
  printf 'ENCRYPTION_KEY=%s\nJWT_SECRET=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > "$dir/.env"
  chmod 600 "$dir/.env"
  # Arcane stoler KUN på APP_URL som gyldig CORS/CSRF-origin (cors_middleware.go/
  # csrf_middleware.go) — innlogging via en annen adresse enn den valgt her vil
  # bli avvist med "Cross-origin request blocked". Lagres slik at print_app_logins
  # kan vise riktig (og eneste faktisk fungerende) adresse.
  printf '%s' "$app_url" > "$dir/.app_url_valgt"
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
  pick_app_url dozzle >/dev/null
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

app_port_airconnect-cast() { printf ''; }
app_port_airconnect-upnp() { printf ''; }
app_repo_airconnect-cast() { printf 'GioF71/airconnect-docker'; }
app_repo_airconnect-upnp() { printf 'GioF71/airconnect-docker'; }

_install_airconnect() { # _install_airconnect <cast|upnp> — bygger og starter én airconnect-variant
  local mode=$1
  local app="airconnect-$mode"
  local dir=$APPS_DIR/$app
  if [ -f "$dir/compose.yml" ]; then skip "$app er alt satt opp i $dir"; return; fi
  ensure_docker
  local uid gid
  uid=$(id -u "$ADMIN_USER"); gid=$(id -g "$ADMIN_USER")
  install -d -o "$ADMIN_USER" -g "$ADMIN_USER" "$dir" "$dir/config"
  printf 'PUID=%s\nPGID=%s\nAIRCONNECT_MODE=%s\n' "$uid" "$gid" "$mode" > "$dir/.env"
  chmod 600 "$dir/.env"
  cat > "$dir/compose.yml" <<EOF
services:
  airconnect:
    image: giof71/airconnect:latest
    container_name: $app
    network_mode: host
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - AIRCONNECT_MODE=\${AIRCONNECT_MODE}
    volumes:
      - ./config:/config
    restart: unless-stopped
EOF
  chown -R "$ADMIN_USER:$ADMIN_USER" "$dir"
  (cd "$dir" && docker compose up -d)
  ok "$app installert og kjører"
}

# airconnect-cast bygger bro mellom AirPlay og Chromecast-enheter,
# airconnect-upnp mellom AirPlay og UPnP/DLNA-enheter (f.eks. upmpdcli/mpd).
# Begge kan installeres samtidig (APP_KATALOG spør om hver for seg).
install_airconnect-cast() { _install_airconnect cast; }
install_airconnect-upnp() { _install_airconnect upnp; }

print_app_logins() {
  local app funnet=0
  for app in $APP_KATALOG; do
    [ -f "$APPS_DIR/$app/compose.yml" ] && { funnet=1; break; }
  done
  [ "$funnet" -eq 1 ] || return 0
  [ -f "$CONF" ] && . "$CONF"
  local ip port ip_url dns_url https_url dns_navn login forste=1
  ip=$(get_lan_ip)
  msg "Innloggingslenker for installerte apper:"
  printf '\n' >&2
  for app in $APP_KATALOG; do
    if [ -f "$APPS_DIR/$app/compose.yml" ]; then
      [ "$forste" -eq 1 ] || printf -- '----------------------------------------\n' >&2
      forste=0
      port=$("app_port_$app")
      printf '\033[1m%s\033[0m\n' "$app" >&2
      if [ -z "$port" ]; then
        printf '  Ingen web-UI — kjører i bakgrunnen (network_mode: host)\n' >&2
      elif [ -f "$APPS_DIR/$app/.app_url_valgt" ]; then
        # Appen stoler kun på denne ene origin (satt som APP_URL/tilsvarende ved
        # installasjon) — andre adresser kan gi CORS/CSRF-feil ved innlogging.
        printf '  Adresse: %s  (eneste adresse appen godtar — valgt ved installasjon)\n' "$(link "$(cat "$APPS_DIR/$app/.app_url_valgt")")" >&2
        login=$("app_login_$app" 2>/dev/null) || login=''
        [ -n "$login" ] && printf '  Innlogging: %s\n' "$login" >&2
      else
        ip_url="http://$ip:$port"
        dns_navn="$LOKASJON-$NODE-$VMID-$app.$DOMENE"
        [ -f "$APPS_DIR/$app/.dns_navn" ] && dns_navn=$(cat "$APPS_DIR/$app/.dns_navn")
        dns_url="http://$dns_navn:$port"
        https_url="https://$dns_navn"
        printf '  IP:    %s\n' "$(link "$ip_url")" >&2
        printf '  DNS:   %s  (krever oppsatt navn)\n' "$(link "$dns_url")" >&2
        printf '  HTTPS: %s  (uten port — krever reverse proxy, f.eks. Zoraxy, på 443)\n' "$(link "$https_url")" >&2
        login=$("app_login_$app" 2>/dev/null) || login=''
        [ -n "$login" ] && printf '  Innlogging: %s\n' "$login" >&2
      fi
    fi
  done
  printf '\n' >&2
}

main() {
  require_root
  detect_os
  if is_pve_host; then
    pve_menu
    exit 0
  fi
  step_system
  step_locale
  step_docker
  step_admin_user
  step_ssh_key
  step_ssh_hardening
  step_identity
  . "$CONF"
  step_apps
  print_app_logins
  if [ "${SSH_PORT:-22}" != "22" ]; then
    ok "Ferdig! Logg inn med: ssh -p $SSH_PORT $ADMIN_USER@$(get_lan_ip)  (SSH-port: $SSH_PORT, ikke standard 22)"
  else
    ok "Ferdig! Logg inn med: ssh $ADMIN_USER@$(get_lan_ip)"
  fi
}
main "$@"
