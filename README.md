# crtx2-install

Richtet einen crtx2-Node ein – auf einem Raspberry Pi oder einer VM, gleich.

```bash
curl -fsSL https://raw.githubusercontent.com/pcas-io/crtx2-install/main/install.sh | sudo bash
```

**Voraussetzung:** Debian 12/13 oder Ubuntu 22.04/24.04 (arm64 oder amd64), ein
normaler Benutzer mit sudo, Internet. Dieser Benutzer wird der Benutzer des Agenten.

**Was das Skript tut**, jeder Schritt prüft sich und lässt sich wiederholen:

1. Vorprüfung (System, Platz, Speicher, Uhr, Netz) – ändert nichts
2. Name des Nodes = Hostname
3. Grundpakete (git, ssh, avahi)
4. Zugang zum Repo – bei einem privaten Repo erzeugt es einen Deploy-Key auf dem
   Node, zeigt ihn an und wartet, bis du ihn bei GitHub eingetragen hast
5. Bootstrap aus dem Repo
6. Übergabe: Adresse der Console und Einmal-Token – Anbieter (Claude, Mistral oder beide) wählst du danach im Browser

Kommt deine Eingabe nicht an (Ubuntu 26.04 und neuer, dort ist sudo-rs Standard:
bei `curl … | sudo bash` erreicht die Tastatur den Installer nicht), lade das Skript
erst herunter – dann funktionieren Eingaben und Enter:

```
curl -fsSLo /tmp/crtx2-install.sh https://raw.githubusercontent.com/pcas-io/crtx2-install/main/install.sh
sudo bash /tmp/crtx2-install.sh
```

Ohne Eingabe nimmt jede Frage nach 60 s die Vorgabe; der Deploy-Key wird ohnehin von
selbst geprüft. Optionen (z. B. `CRTX2_DOCKER=1`, `CRTX2_NAME=<name>`) vor `bash`.

Nur prüfen: `curl … | sudo bash -s -- --check`
Unbeaufsichtigt: `curl … | sudo CRTX2_NAME=<name> bash` (Repo ist `pcas-io/crtx2`, ein anderes: `CRTX2_REPO=<owner/name>`)

Das Skript enthält keine Zugangsdaten. Das Repo und den Namen fragt es ab.
Protokoll: `/var/log/crtx2-install.log` (der Einmal-Token steht nicht darin).
