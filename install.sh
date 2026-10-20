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
#   3 Grundpakete                    6 Uebergabe: Claim-Adresse und Einmal-Token
#
# Unbeaufsichtigt (kein Terminal): CRTX2_NAME=<name>, anderes Repo: CRTX2_REPO=<owner/name>
# Nur pruefen: ... | sudo bash -s -- --check
set -euo pipefail

# Alles steckt in main(), das erst in der letzten Zeile aufgerufen wird, und
# zwar mit stdin aus /dev/null. Zwei Gruende (curl | bash):
#  1. Bricht der Download mitten im Skript ab, laeuft nichts Halbes los.
#  2. Unterprozesse (git, ssh, apt) erben sonst die Pipe als stdin; git clone
#     hing daran am 2026-10-18 auf zer0 unbegrenzt (derselbe Klon mit
#     </dev/null: 2,5 s). Fragen liest frage() ausdruecklich von /dev/tty.
main() {

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
  # Die Frage direkt aufs Terminal schreiben, nicht ueber stderr: stderr laeuft hier durch
  # die Log-Umleitung (tee), und read -p blieb so auf Ubuntu 26.04 (sudo-rs) unsichtbar –
  # der Installer wartete stumm (ifp-hq-harness, 2026-10-20).
  if [ -n "$TTY" ]; then printf '  %s [%s]: ' "$1" "$2" > "$TTY"; read -r a < "$TTY" || true; fi
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
for ziel in github.com:443 ssh.github.com:443 registry.npmjs.org:443 deb.nodesource.com:443 discord.com:443; do
  if timeout 6 bash -c "exec 3<>/dev/tcp/${ziel%:*}/${ziel#*:}" 2>/dev/null; then ok "erreichbar: $ziel"
  elif [ "$ziel" = discord.com:443 ]; then warn "discord.com nicht erreichbar – Discord geht später nicht"
  else nein "nicht erreichbar: $ziel"; fehler=1; fi
done
[ "$fehler" = 0 ] || stopp "die Vorprüfung hat Punkte mit ✗ – nichts wurde verändert."
[ "$CHECK_ONLY" = 1 ] && { printf '\nVorprüfung bestanden – nichts verändert.\n'; exit 0; }

# ── 2 Name ──────────────────────────────────────────────────────────────────
schritt "2 · Name des Nodes"
jetzt=$(hostname -s)
NAME=${CRTX2_NAME:-$(frage "So heißt der Node überall (Console, Discord, claude.ai/code, <name>.local)" "$jetzt")}
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
# Keine Frage mehr (Lauf 6, Befund 40): das Repo ist fast immer dasselbe.
# Ein anderes setzt CRTX2_REPO=<owner/name> vor bash.
REPO=${CRTX2_REPO:-pcas-io/crtx2}
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || stopp "Repo '$REPO': bitte als owner/name."
ok "Repo: $REPO (ein anderes: CRTX2_REPO=<owner/name> vor bash)"
if timeout 20 git ls-remote "https://github.com/$REPO.git" HEAD >/dev/null 2>&1; then
  URL="https://github.com/$REPO.git"; SSH_URL=""
  ok "öffentliches Repo – kein Schlüssel nötig"
else
  install -d -m 700 /etc/crtx2
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "crtx2-$NAME" -f "$KEY"
  chmod 600 "$KEY"
  # Immer SSH ueber Port 443 (ssh.github.com, GitHubs offizieller Weg durch
  # Firewalls). Lauf 5 (agentic-zero): Port 22 brach zeitweise mit "Connection
  # timed out" ab, waehrend 443 sofort antwortete — die Vorpruefung hatte 22
  # Sekunden vorher noch erreicht.
  SSH_URL="ssh://git@ssh.github.com:443/$REPO.git"
  export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  if ! timeout 20 git ls-remote "$SSH_URL" HEAD >/dev/null 2>&1; then
    printf '\n  Das Repo ist privat. Trag diesen Schlüssel als %sDeploy Key%s ein (nur lesen, %skein%s Haken bei „Allow write access“):\n\n' "$B" "$N" "$B" "$N"
    printf '    https://github.com/%s/settings/keys/new\n\n    %s\n\n' "$REPO" "$(cat "$KEY.pub")"
    printf '  Ich prüfe von selbst – du musst nichts bestätigen. Enter prüft sofort.\n  '
    # Abstand waechst von 5 auf 30 s: viele abgewiesene SSH-Anmeldungen in
    # kurzer Folge bremst GitHub vermutlich aus (Lauf 4/5: danach hing jeder
    # Klon bis zur Zeitgrenze, mit Abstand dauerte er 2 s).
    warte=5; bis=$((SECONDS + 900)); zugang=0
    while [ "$SECONDS" -lt "$bis" ]; do
      if timeout 20 git ls-remote "$SSH_URL" HEAD >/dev/null 2>&1; then zugang=1; printf '\n'; break; fi
      printf '.'
      if [ -n "$TTY" ]; then read -r -t "$warte" _ < "$TTY" || true; else sleep "$warte"; fi
      [ "$warte" -lt 30 ] && warte=$((warte + 5))
    done
    [ "$zugang" = 1 ] || stopp "kein Zugang zum Repo – Schlüssel eingetragen? Dann denselben Befehl noch einmal."
    sleep 10  # Abstand zur letzten Abweisung, bevor der Klon startet
  fi
  URL="$SSH_URL"
  ok "Zugang zum Repo per Deploy-Key"
fi
# Ein halber Klon (abgebrochener Lauf) hat kein HEAD: dann neu holen statt flicken.
if [ -d "$SRC/.git" ] && ! git -C "$SRC" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  rm -rf "$SRC"
  warn "halber Klon vom letzten Lauf entfernt"
fi
if [ -d "$SRC/.git" ]; then
  timeout 300 git -C "$SRC" fetch -q origin && git -C "$SRC" checkout -q --detach origin/HEAD \
    || stopp "Quelle nicht aktualisierbar (git fetch) – Netz zu GitHub prüfen, dann denselben Befehl noch einmal."
  ok "Quelle aktualisiert: $SRC"
else
  # Bis zu 3 Versuche mit 60 s Grenze und wachsender Pause, statt einem
  # einzigen Versuch, der 5 min haengen kann.
  geholt=0
  for pause in 0 20 60; do
    sleep "$pause"
    rm -rf "$SRC"
    if timeout 60 git clone -q --depth 1 "$URL" "$SRC"; then geholt=1; break; fi
    warn "Klon nicht fertig geworden – neuer Versuch"
  done
  [ "$geholt" = 1 ] || stopp "Quelle nicht geholt (3 Versuche) – Netz zu GitHub prüfen, dann denselben Befehl noch einmal."
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
printf '  Danach wählst du in der Console den Anbieter – Claude, Mistral oder beide –\n'
printf '  und meldest den Agenten an, ohne SSH. Mit Claude erscheint er als „%s claude“ in claude.ai/code.\n' "$NAME"
printf '\n%sFertig.%s Protokoll: %s\n' "$G" "$N" "$LOG"
}

main "$@" </dev/null
