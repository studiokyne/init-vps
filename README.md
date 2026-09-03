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
- **Ports Docker filtrés** — UFW ne filtre pas les ports publiés par les conteneurs ; le script pose des règles `DOCKER-USER` pour combler ce trou (voir plus bas).
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

### Mettre à jour un serveur déjà initialisé

Pour propager une nouvelle version du script (nouveau MOTD, nouvelle commande
`vps-helper`, nouvelle règle sysctl…) sur un serveur déjà configuré :

```bash
curl -fsSL https://github.com/studiokyne/init-vps/releases/latest/download/init-vps.sh \
  -o init-vps.sh && chmod +x init-vps.sh && sudo ./init-vps.sh --update
```

La configuration est relue depuis `/etc/init-vps/config.env` : **aucune question
n'est reposée**, et toutes les étapes sont rejouées. Elles sont idempotentes, donc
celles déjà en place sont simplement ignorées — y compris le verrouillage SSH, qui
ne redemande aucune confirmation. La mise à jour des paquets système est volontairement
sautée dans ce mode.

Sans `--update`, le script détecte quand même la configuration existante et propose
le mode mise à jour ; le drapeau ne fait que répondre « oui » d'avance.

> [!NOTE]
> À ne pas confondre avec `vps-helper update`, qui met à jour les **paquets du système**
> (`apt`) et ne touche pas à la configuration posée par ce script.

---

## 🧭 Étapes exécutées

| #   | Étape                                               | #   | Étape                                             |
| --- | --------------------------------------------------- | --- | ------------------------------------------------- |
| 0   | Collecte interactive + récapitulatif + confirmation | 11  | Swap (taille selon la RAM détectée)               |
| 1   | Mise à jour du système                              | 12  | Fuseau horaire / NTP / logs journald              |
| 2   | Définition du hostname                              | 13  | MOTD personnalisé                                 |
| 3   | Compte admin (sudo) + clé(s) SSH                    | 14  | Commande d'aide `vps-helper`                      |
| 4   | fail2ban (activé **avant** l'ouverture SSH)         | 15  | Limitation des logs Docker                        |
| 5   | Durcissement SSH — phase 1 (transition)             | 16  | Pare-feu des ports publiés par Docker             |
| 6   | UFW (pare-feu, dont UDP/443 pour HTTP/3)            | 17  | Audit des ports publiés (lecture seule)           |
| 7   | Durcissement SSH — phase 2 (verrouillage)           | 18  | Installation de Dokploy                           |
| 8   | Verrouillage du compte root                         | 19  | Optimisation Traefik (HTTP/3 + compression)       |
| 9   | unattended-upgrades (MAJ sécurité auto)             | 20  | Sauvegarde de la configuration (mode `--update`)  |
| 10  | Durcissement sysctl (réseau + mémoire + perfs)      |     |                                                   |

`needrestart` est réglé en mode automatique **avant** l'étape 1, pour qu'aucun menu interactif n'interrompe le `dist-upgrade`.

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
| `vps-helper docker-firewall <status\|apply\|clear>` | État / (re)pose / retrait du filtrage `DOCKER-USER` |
| `vps-helper version`           | Afficher la version de `init-vps.sh` utilisée                 |
| `vps-helper help`              | Afficher l'aide                                               |

### `vps-helper check`

Audit de lecture seule. Vérifie :

- **SSH** — `PermitRootLogin no` et `PasswordAuthentication no` (config effective via `sshd -T`)
- **UFW** — actif, politique par défaut `deny incoming`
- **fail2ban** — service actif, jails `sshd` et `recidive`
- **Compte root** — verrouillé
- **Docker** — rotation des logs (`max-size` dans `daemon.json`)
- **Ports publiés par Docker** — tout port exposé sur `0.0.0.0` hors 80/443, et état de la chaîne `DOCKER-USER`
- **Traefik** — HTTP/3 activé, middleware `compression` attaché à `websecure`
- **unattended-upgrades** — service actif
- **Informationnel** — swap, port 3000, redémarrage requis, état Docker Swarm

---

## 🔥 Ports publiés par Docker : le trou que UFW ne bouche pas

UFW **ne filtre pas** les ports publiés par les conteneurs. Le trafic vers un conteneur traverse la chaîne `FORWARD` (`DOCKER-USER`, `DOCKER-FORWARD`) et ne passe jamais par les chaînes `ufw-*`. Mesuré sur un serveur en production : 102 M de paquets vus par `DOCKER-USER`, **0** par toutes les chaînes `ufw-*forward`.

Conséquence : un `-p 3000:3000` est joignable depuis Internet même si aucune règle UFW ne l'autorise — et `ufw status` n'en dit rien.

Le script pose donc des règles dans `DOCKER-USER`, le point d'accroche officiel prévu par Docker :

- `RETURN` sur les connexions établies, sur 80, 443/tcp, 443/udp et sur les réseaux privés (RFC1918) entrants ;
- `DROP` sur tout le reste arrivant par l'interface publique (celle de la route par défaut) ;
- persistance par l'unit systemd `docker-user-rules.service` et le script `/usr/local/lib/docker-user/apply.sh`.

Contrairement à `ufw-docker`, cette approche survit aux redémarrages et ne casse ni l'ingress Swarm ni `docker_gwbridge` : seul ce qui entre par l'interface publique est bloqué.

**Comportement selon le contexte :**

| Contexte                                   | Comportement                                                                     |
| ------------------------------------------ | -------------------------------------------------------------------------------- |
| Première installation                      | Règles appliquées directement — aucun conteneur n'existe encore, rien à casser    |
| Mode `--update` avec des conteneurs actifs | Les ports qui seraient coupés sont listés, puis confirmation demandée (défaut : non) |
| Règles `DOCKER-USER` déjà posées par un tiers | Rien n'est modifié, un avertissement est affiché                                |

Pilotage après coup : `vps-helper docker-firewall status|apply|clear`. `clear` est le filet de sécurité si les règles cassent un service.

> **Un pare-feu externe reste recommandé** en défense en profondeur (Hetzner Cloud Firewall, security groups…). Il filtre en amont de la machine, donc avant même que Docker ou iptables n'entrent en jeu, et il survit à une erreur de configuration locale. Attention en revanche : il est **invisible depuis le serveur** — ni `ufw status`, ni `vps-helper check` ne peuvent le voir. Ne pas confondre « aucune alerte » avec « protégé ».

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
