# serveroppsett

Generisk bootstrap-skript for ferske Linux-servere (Debian/Ubuntu/Fedora m.fl.).
Oppdaterer systemet, installerer Docker (siste versjon), oppretter en admin-bruker
med SSH-nøkkel, stenger root- og passordinnlogging over SSH, og tilbyr installasjon
av Docker-apper (Arcane m.fl.) i en struktur der Arcane styrer alle apper.

## Bruk

Kjør som root på en fersk server:

    curl -fsSL https://raw.githubusercontent.com/RayBomb87/serveroppsett/main/setup.sh | bash

Mangler `curl` (vanlig i ferske Debian-LXC-maler): kjør først
`apt-get update && apt-get install -y curl`, eller bruk wget-varianten:

    wget -qO- https://raw.githubusercontent.com/RayBomb87/serveroppsett/main/setup.sh | bash

Docker i LXC krever at containeren har **nesting** aktivert i Proxmox.

Skriptet spør om alt det trenger: brukernavn, SSH-nøkkel (hentes evt. fra
`github.com/<konto>.keys`), server-identitet og hvilke apper som skal installeres.
Trygt å kjøre flere ganger — ferdige steg hoppes over.
