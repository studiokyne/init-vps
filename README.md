<div align="center">

# 🛡️ init-vps

**Initialisation et durcissement de VPS Ubuntu / Debian, prêt pour [Dokploy](https://dokploy.com).**

Un seul script bash, 100 % interactif, idempotent — du serveur nu au serveur durci et prêt à déployer.

[![Lint](https://github.com/studiokyne/init-vps/actions/workflows/lint.yml/badge.svg)](https://github.com/studiokyne/init-vps/actions/workflows/lint.yml)
[![Licence: MIT](https://img.shields.io/badge/Licence-MIT-blue.svg)](LICENSE)
[![Shell: bash](https://img.shields.io/badge/Shell-bash-121011.svg?logo=gnu-bash&logoColor=white)](init-vps.sh)
[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420.svg?logo=ubuntu&logoColor=white)](https://ubuntu.com)

</div>

---

## ✨ En bref

- **Un seul fichier** — aucune dépendance à cloner, installable en une commande `curl | bash`.
- **Interactif et guidé** — chaque question a une valeur par défaut ; chaque saisie est validée.
- **Idempotent** — relançable sans risque : les étapes déjà appliquées sont détectées et ignorées.
- **Sécurisé par défaut** — fail2ban activé _avant_ l'ouverture SSH, verrouillage SSH en deux phases avec validation manuelle, root verrouillé, UFW, durcissement sysctl.
- **Prêt pour Dokploy** — installe Dokploy et optimise Traefik (HTTP/3 + compression Brotli/Zstd).
- **`vps-helper`** — une commande d'administration installée sur le serveur pour l'exploitation quotidienne.

---

## 📋 Prérequis

- Ubuntu 24.04 LTS ou Debian (testé sur Ubuntu 24.04, compatible futures LTS)
- Accès **root** au serveur (`sudo` ou connexion en root)
- Un serveur **fraîchement installé** (le script durcit et verrouille l'accès)

---

## 🚀 Installation

### Commande unique (recommandée)

```bash
curl -fsSL https://github.com/studiokyne/init-vps/releases/latest/download/init-vps.sh \
  -o init-vps.sh && chmod +x init-vps.sh && sudo ./init-vps.sh
```

### Clone + exécution locale

```bash
git clone https://github.com/studiokyne/init-vps.git
cd init-vps
sudo ./init-vps.sh
```

> [!IMPORTANT]
> Le verrouillage SSH (phase 2) attend une **confirmation manuelle**. Garde ta session ouverte et teste la connexion avec le compte admin dans un **autre terminal** avant de valider — c'est le filet de sécurité qui évite de te verrouiller dehors.

---

## 🧭 Étapes exécutées

| #   | Étape                                               | #   | Étape                                       |
| --- | --------------------------------------------------- | --- | ------------------------------------------- |
| 0   | Collecte interactive + récapitulatif + confirmation | 9   | unattended-upgrades (MAJ sécurité auto)     |
| 1   | Mise à jour du système                              | 10  | Durcissement sysctl réseau                  |
| 2   | Définition du hostname                              | 11  | Swap (taille selon la RAM détectée)         |
| 3   | Compte admin (sudo) + clé(s) SSH                    | 12  | Fuseau horaire / NTP / logs journald        |
| 4   | fail2ban (activé **avant** l'ouverture SSH)         | 13  | MOTD personnalisé                           |
| 5   | Durcissement SSH — phase 1 (transition)             | 14  | Commande d'aide `vps-helper`                |
| 6   | UFW (pare-feu, dont UDP/443 pour HTTP/3)            | 15  | Limitation des logs Docker                  |
| 7   | Durcissement SSH — phase 2 (verrouillage)           | 16  | Installation de Dokploy                     |
| 8   | Verrouillage du compte root                         | 17  | Optimisation Traefik (HTTP/3 + compression) |

Un résumé final est affiché et sauvegardé dans `/var/log/init-vps.log`.

---

## 🏷️ Convention de nommage des hostnames

Format : `type-objectif-zone-numero`

| Segment    | Exemples                                    |
| ---------- | ------------------------------------------- |
| `type`     | `vps`, `bare`, `nas`, `vm`                  |
| `objectif` | `client`, `internal`, `backup`, `storage`   |
| `zone`     | `nbg1`, `hel1`, `fsn1` (datacenter Hetzner) |
| `numero`   | `1`, `2`, `01`, `02`…                       |

Exemples : `vps-client-nbg1-1`, `vps-internal-nbg1-1`, `storage-backup-nbg1-1`.

> Le nom du client n'apparaît **jamais** en clair dans le hostname : un VPS peut héberger plusieurs clients, et le hostname est visible dans de nombreux logs.

---

## 🧰 vps-helper

Commande d'administration installée sur le serveur lors de l'initialisation.

| Commande                       | Description                                                   |
| ------------------------------ | ------------------------------------------------------------- |
| `vps-helper status`            | État du serveur (identique au message de connexion SSH)       |
| `vps-helper whitelist <IP>`    | Ajouter une IP de confiance (jamais bannie par fail2ban)      |
| `vps-helper unban <IP>`        | Débannir une IP bannie par fail2ban                           |
| `vps-helper close-dokploy`     | Fermer l'accès direct au port 3000 (Dokploy)                  |
| `vps-helper restart <service>` | Redémarrer un service : `ssh`, `fail2ban`, `docker`           |
| `vps-helper logs <conteneur>`  | Afficher les logs d'un conteneur Docker (Ctrl+C pour quitter) |
| `vps-helper update`            | Mettre à jour le système (sécurité incluse)                   |
| `vps-helper check`             | Auditer le durcissement en lecture seule (PASS / FAIL / INFO) |
| `vps-helper traefik-tuning`    | Activer HTTP/3 + compression Traefik (idempotent)             |
| `vps-helper version`           | Afficher la version de `init-vps.sh` utilisée                 |
| `vps-helper help`              | Afficher l'aide                                               |

### `vps-helper check`

Audit de lecture seule. Vérifie :

- **SSH** — `PermitRootLogin no` et `PasswordAuthentication no` (config effective via `sshd -T`)
- **UFW** — actif, politique par défaut `deny incoming`
- **fail2ban** — service actif, jails `sshd` et `recidive`
- **Compte root** — verrouillé
- **Docker** — rotation des logs (`max-size` dans `daemon.json`)
- **Traefik** — HTTP/3 activé, middleware `compression` attaché à `websecure`
- **unattended-upgrades** — service actif
- **Informationnel** — swap, port 3000, redémarrage requis, état Docker Swarm

---

## ⚡ Optimisation Traefik (HTTP/3 + compression)

L'étape 17 (et la commande `vps-helper traefik-tuning`) applique un **patch idempotent** à la configuration Traefik générée par Dokploy :

- **HTTP/3 (QUIC)** sur l'entrypoint `websecure` — le port **UDP/443** est ouvert dans UFW.
- **Compression** `zstd` / `br` / `gzip` via un middleware `compression`, appliqué globalement sur `websecure`.

Le patch est appliqué avec [`yq`](https://github.com/mikefarah/yq) (installé automatiquement si absent) pour **préserver** les middlewares gérés par Dokploy — jamais de réécriture destructive. Une sauvegarde horodatée des fichiers Traefik est créée avant toute modification.

> [!NOTE]
> Traefik pouvant régénérer `traefik.yml` lors de certaines mises à jour de Dokploy, le patch peut être réappliqué à tout moment : `sudo vps-helper traefik-tuning`.

---

## 🔖 Versioning

Chaque push sur `main` déclenche automatiquement une release, au format `YYYY.MM.DD.N` (N = incrément du jour, repart à 1 chaque jour).

Exemples : `2026.06.21.1`, `2026.06.21.2`, `2026.07.01.1`

À chaque push, le workflow CI/CD :

1. Lance ShellCheck + vérification syntaxique du script et des heredocs
2. Calcule la prochaine version du jour
3. Injecte la version dans `SCRIPT_VERSION` (sur une copie — `main` conserve `0.0.0-dev`)
4. Publie une GitHub Release avec le script versionné en asset

La version installée sur un serveur est accessible via `vps-helper version`.

---

## 📄 Licence

[MIT](LICENSE) — © 2026 Studio Kyne and contributors
