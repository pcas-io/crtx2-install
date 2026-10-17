#!/usr/bin/env bash
# shellcheck disable=SC2015,SC1091  # Pruefzeilen „a && ok || nein“ sind gewollt; os-release ist Systemdatei
# install.sh — einen crtx2-Node einrichten, auf dem Node selbst.
#
#   curl -fsSL https://raw.githubusercontent.com/pcas-io/crtx2-install/main/install.sh | sudo bash
#
# Laeuft gleich auf einem Raspberry Pi und auf einer VM: Debian 12/13 oder
# Ubuntu 22.04/24.04, arm64 oder amd64. Harness-Benutzer ist, wer das Skript
# per sudo startet. Das Skript enthaelt keine Zugangsdaten und keine Adressen:
# das Repo und den Namen fragt es ab (oder nimmt sie aus der Umgebung).
#
# Ablauf, jeder Schritt prueft sich und laesst sich wiederholen:
#   1 Vorpruefung (aendert nichts)   4 Zugang zum Repo (Deploy-Key)
#   2 Name des Nodes (= Hostname)    5 Bootstrap aus dem Repo
#   3 Grundpakete                    6 Uebergabe: Claim-Adresse, Claude-Login
#
# Unbeaufsichtigt (kein Terminal): CRTX2_REPO=<owner/name> CRTX2_NAME=<name>
# Nur pruefen: ... | sudo bash -s -- --check
set -euo pipefail

LOG=/var/log/crtx2-install.log
KEY=/etc/crtx2/deploy-key
SRC=/opt/crtx2-src
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# ── Ausgabe ─────────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; else B=; G=; R=; Y=; N=; fi
schritt() { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }
ok()      { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn()    { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
nein()    { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
stopp()   { printf '\n%sNicht weiter:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

TTY=""
[ -r /dev/tty ] && { : < /dev/tty; } 2>/dev/null && TTY=/dev/tty
frage() {  # frage <Text> <Vorgabe> -> Antwort (oder Vorgabe ohne Terminal)
  local a=""
  if [ -n "$TTY" ]; then read -r -p "  $1 [$2]: " a < "$TTY" || true; fi
  printf '%s' "${a:-$2}"
}

[ "$(id -u)" = 0 ] || stopp "bitte mit sudo starten: curl … | sudo bash"
USR=${SUDO_USER:-}
if [ -z "$USR" ] || [ "$USR" = root ]; then
  stopp "bitte als normaler Benutzer anmelden und mit sudo starten – dieser Benutzer wird der Benutzer des Agenten."
fi
UHOME=$(getent passwd "$USR" | cut -d: -f6)

if [ "$CHECK_ONLY" = 0 ]; then
  ( umask 077; : >> "$LOG" ); chmod 600 "$LOG"
  exec > >(tee -a "$LOG") 2>&1
fi
printf '%scrtx2 – Node einrichten%s  (%s, Benutzer %s)\n' "$B" "$N" "$(date -Is)" "$USR"

# ── 1 Vorpruefung ───────────────────────────────────────────────────────────
schritt "1 · Vorprüfung – ändert nichts"
fehler=0
. /etc/os-release 2>/dev/null || true
case "${ID:-}:${VERSION_ID:-}" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|raspbian:12|raspbian:13) ok "System: ${PRETTY_NAME:-$ID}" ;;
  debian:*|ubuntu:*|raspbian:*) warn "System ${PRETTY_NAME:-$ID} ist nicht erprobt – es geht weiter" ;;
  *) nein "System ${PRETTY_NAME:-unbekannt}: gebraucht wird Debian oder Ubuntu"; fehler=1 ;;
esac
case "$(uname -m)" in
  aarch64|arm64|x86_64|amd64) ok "Architektur: $(uname -m)" ;;
  *) nein "Architektur $(uname -m): gebraucht wird arm64 oder amd64"; fehler=1 ;;
esac
[ -d /run/systemd/system ] && ok "systemd läuft" || { nein "kein systemd – die Dienste brauchen es"; fehler=1; }
frei=$(df -Pm / | awk 'NR==2 {print $4}')
[ "${frei:-0}" -ge 4096 ] && ok "Platz: $((frei / 1024)) GB frei" || { nein "nur ${frei:-?} MB frei, gebraucht werden 4 GB"; fehler=1; }
ram=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "${ram:-0}" -ge 1800 ] && ok "Arbeitsspeicher: $ram MB" || { nein "nur ${ram:-?} MB RAM, gebraucht werden 2 GB"; fehler=1; }
[ "$(id -u "$USR")" -ge 1000 ] && ok "Benutzer des Agenten: $USR ($UHOME)" || { nein "$USR ist ein Systembenutzer"; fehler=1; }
uhr=no
command -v timedatectl >/dev/null || uhr=unbekannt
[ "$uhr" = unbekannt ] || for _ in $(seq 24); do
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && { uhr=yes; break; }
  sleep 5
done
case $uhr in
  yes) ok "Uhr synchron" ;;
  unbekannt) warn "Uhr nicht prüfbar (kein timedatectl)" ;;
  *) warn "Uhr nach 2 min nicht synchron – Downloads können scheitern" ;;
esac
for ziel in github.com:443 github.com:22 registry.npmjs.org:443 deb.nodesource.com:443 discord.com:443; do
  if timeout 6 bash -c "exec 3<>/dev/tcp/${ziel%:*}/${ziel#*:}" 2>/dev/null; then ok "erreichbar: $ziel"
  elif [ "$ziel" = github.com:22 ]; then warn "github.com:22 gesperrt – ich nehme Port 443"
  elif [ "$ziel" = discord.com:443 ]; then warn "discord.com nicht erreichbar – Discord geht später nicht"
  else nein "nicht erreichbar: $ziel"; fehler=1; fi
done
[ "$fehler" = 0 ] || stopp "die Vorprüfung hat Punkte mit ✗ – nichts wurde verändert."
[ "$CHECK_ONLY" = 1 ] && { printf '\nVorprüfung bestanden – nichts verändert.\n'; exit 0; }

# ── 2 Name ──────────────────────────────────────────────────────────────────
schritt "2 · Name des Nodes"
jetzt=$(hostname -s)
NAME=${CRTX2_NAME:-$(frage "So heißt der Node überall (Console, claude.ai/code, <name>.local)" "$jetzt")}
NAME=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')
printf '%s' "$NAME" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$' \
  || stopp "Name '$NAME': nur a-z, 0-9 und -, nicht am Anfang oder Ende."
if [ "$NAME" != "$jetzt" ]; then
  hostnamectl set-hostname "$NAME"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NAME/" /etc/hosts
  else printf '127.0.1.1\t%s\n' "$NAME" >> /etc/hosts; fi
  ok "Hostname gesetzt: $NAME"
else
  ok "Name: $NAME"
fi

# ── 3 Grundpakete ───────────────────────────────────────────────────────────
schritt "3 · Grundpakete"
export DEBIAN_FRONTEND=noninteractive GIT_TERMINAL_PROMPT=0
apt-get update -qq
apt-get install -y -qq git openssh-client avahi-daemon ca-certificates curl >/dev/null
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
systemctl restart avahi-daemon >/dev/null 2>&1 || true
ok "git, ssh, avahi ($NAME.local) installiert"

# ── 4 Zugang zum Repo ───────────────────────────────────────────────────────
schritt "4 · Zugang zum Repo"
REPO=${CRTX2_REPO:-}
[ -n "$REPO" ] || REPO=$(frage "Welches Repo? (owner/name auf GitHub)" "")
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || stopp "Repo '$REPO': bitte als owner/name."
if git ls-remote "https://github.com/$REPO.git" HEAD >/dev/null 2>&1; then
  URL="https://github.com/$REPO.git"; SSH_URL=""
  ok "öffentliches Repo – kein Schlüssel nötig"
else
  install -d -m 700 /etc/crtx2
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "crtx2-$NAME" -f "$KEY"
  chmod 600 "$KEY"
  SSH_URL="git@github.com:$REPO.git"
  timeout 6 bash -c 'exec 3<>/dev/tcp/github.com/22' 2>/dev/null || SSH_URL="ssh://git@ssh.github.com:443/$REPO.git"
  export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  if ! git ls-remote "$SSH_URL" HEAD >/dev/null 2>&1; then
    printf '\n  Das Repo ist privat. Trag diesen Schlüssel als %sDeploy Key%s ein (nur lesen, %skein%s Haken bei „Allow write access“):\n\n' "$B" "$N" "$B" "$N"
    printf '    https://github.com/%s/settings/keys/new\n\n    %s\n\n' "$REPO" "$(cat "$KEY.pub")"
    printf '  Ich warte, bis der Zugang klappt (höchstens 15 min) …\n'
    for _ in $(seq 180); do
      git ls-remote "$SSH_URL" HEAD >/dev/null 2>&1 && break
      sleep 5
    done
  fi
  git ls-remote "$SSH_URL" HEAD >/dev/null 2>&1 || stopp "kein Zugang zum Repo – Schlüssel eingetragen? Dann denselben Befehl noch einmal."
  URL="$SSH_URL"
  ok "Zugang zum Repo per Deploy-Key"
fi
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch -q origin && git -C "$SRC" checkout -q --detach origin/HEAD
  ok "Quelle aktualisiert: $SRC"
else
  git clone -q --depth 1 "$URL" "$SRC"
  ok "Quelle geholt: $SRC"
fi

# ── 5 Bootstrap ─────────────────────────────────────────────────────────────
schritt "5 · Einrichten (Bootstrap)"
REPO_URL="https://github.com/$REPO" REPO_SSH="$URL" AGENT_USER="$USR" \
  bash "$SRC/scripts/bootstrap.sh" || stopp "der Bootstrap ist abgebrochen – Grund steht oben und in /var/log/crtx2-bootstrap.log. Derselbe Befehl setzt wieder an."

# ── 6 Uebergabe ─────────────────────────────────────────────────────────────
schritt "6 · Übergabe"
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -f /home/console/console-state/admin.json ]; then
  ok "Console ist schon übernommen: https://$NAME.local:8443"
else
  printf '  Console übernehmen:  %shttps://%s.local:8443/claim%s   (oder https://%s:8443/claim)\n' "$B" "$NAME" "$N" "${ip:-<ip>}"
  token=""
  for _ in $(seq 20); do
    token=$(journalctl -u console --no-pager -o cat 2>/dev/null | sed -n 's/.*SETUP TOKEN[^:]*: *//p' | tail -1 || true)
    [ -n "$token" ] && break
    sleep 2
  done
  # Der Token geht nur ans Terminal, nie ins Protokoll.
  if [ -n "$token" ] && [ -n "$TTY" ]; then printf '  Einmal-Token:        %s%s%s (24 h)\n' "$B" "$token" "$N" > "$TTY"
  else printf '  Einmal-Token: sudo journalctl -u console | grep "SETUP TOKEN" | tail -1\n'; fi
fi
printf '  Bis zum Übernehmen wartet der Agent – danach erscheint er als „%s claude“ in claude.ai/code.\n' "$NAME"
if [ -n "$TTY" ] && sudo -u "$USR" -i bash -lc 'claude auth status 2>/dev/null' | grep -q '"loggedIn": *true'; then
  ok "Claude ist schon angemeldet"
elif [ -n "$TTY" ]; then
  a=$(frage "Jetzt bei Claude anmelden? (j/n)" "j")
  # shellcheck disable=SC2024,SC2094  # Umleitung als root ans eigene Terminal ist gewollt
  if [ "$a" = j ]; then sudo -u "$USR" -i bash -lc 'claude auth login' < "$TTY" > "$TTY" 2>&1 || warn "Anmeldung nicht abgeschlossen – später: claude auth login"; fi
fi
printf '\n%sFertig.%s Protokoll: %s\n' "$G" "$N" "$LOG"
