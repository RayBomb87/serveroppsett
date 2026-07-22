# serveroppsett

Generisk bootstrap-skript for ferske Linux-servere (Debian/Ubuntu/Fedora m.fl.).
Oppdaterer systemet, installerer Docker (siste versjon), oppretter en admin-bruker
med SSH-nøkkel, stenger root- og passordinnlogging over SSH, og tilbyr installasjon
av Docker-apper (Arcane m.fl.) i en struktur der Arcane styrer alle apper.

## Bruk

Er du allerede root (f.eks. rett etter `su -`, eller i en fersk LXC/VM):

    curl -fsSL https://raw.githubusercontent.com/RayBomb87/serveroppsett/main/setup.sh | bash

Må du bruke `sudo` for å bli root (vanlig innlogging som en vanlig bruker):

    sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RayBomb87/serveroppsett/main/setup.sh)"

**Ikke** bruk `curl ... | sudo bash` (pipe rett inn i sudo) — da mister sudo sin
egen pty-videresending muligheten til å sende tastetrykk videre til de
interaktive whiptail-menyene (piltaster ekkoes bare rått i stedet for å styre
dem). Skriptet oppdager denne kombinasjonen selv og stopper med en forklaring
i stedet for å late som noe fungerer.

Mangler `curl` (vanlig i ferske Debian-LXC-maler): kjør først
`apt-get update && apt-get install -y curl`, eller bruk wget-varianten
(samme to former som over, bytt `curl -fsSL ... | bash` med
`wget -qO- ... | bash` og `$(curl -fsSL ...)` med `$(wget -qO- ...)`).

Docker i LXC krever at containeren har **nesting** aktivert i Proxmox.

Skriptet spør om alt det trenger: brukernavn, SSH-nøkkel (hentes evt. fra
`github.com/<konto>.keys`), server-identitet og hvilke apper som skal installeres.
Trygt å kjøre flere ganger — ferdige steg hoppes over.
