# init-vps.sh

Script bash d'initialisation et de durcissement de VPS Ubuntu/Debian, prêt pour [Dokploy](https://dokploy.com).

![Lint](https://github.com/studiokyne/init-vps/actions/workflows/lint.yml/badge.svg)

---

## Prérequis

- Ubuntu 24.04 LTS ou Debian (testé sur Ubuntu 24.04, compatible futures LTS)
- Accès root au serveur (`sudo` ou connexion en root)

---

## Installation

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

Le script est **100 % interactif** : il pose toutes les questions au fur et à mesure, avec des valeurs par défaut entre crochets (Entrée pour accepter). Aucun flag n'automatise les réponses (sauf `--version`).

---

## Étapes exécutées

```
 0. Collecte interactive de la configuration + récapitulatif + confirmation
 1. Mise à jour du système
 2. Définition du hostname
 3. Création du compte admin (sudo) + clé(s) SSH
 4. fail2ban (activé AVANT l'ouverture SSH, pas de fenêtre exposée)
 5. Durcissement SSH — phase 1 (transition, root encore actif en filet de
    sécurité le temps de valider l'accès au compte admin)
 6. UFW (pare-feu)
 7. Durcissement SSH — phase 2 (verrouillage final, après confirmation
    manuelle que la connexion admin/sudo fonctionne)
 8. Verrouillage du compte root (défense en profondeur, en plus du SSH)
 9. unattended-upgrades (MAJ sécurité auto, sans reboot)
10. Durcissement sysctl réseau
11. Swap (taille recommandée selon la RAM détectée, ajustable)
12. Fuseau horaire / NTP / limites des logs journald
13. MOTD personnalisé (design uniforme à la connexion SSH)
14. Commande d'aide vps-helper (whitelist, restart, logs, update...)
15. Limitation des logs Docker (rotation 10 Mo x 3 par conteneur)
16. Installation de Dokploy
```

---

## Convention de nommage des hostnames

Format : `type-objectif-zone-numero`

| Segment   | Exemples                                      |
|-----------|-----------------------------------------------|
| `type`    | `vps`, `bare`, `nas`, `vm`                    |
| `objectif`| `client`, `internal`, `backup`, `storage`     |
| `zone`    | `nbg1`, `hel1`, `fsn1` (datacenter Hetzner)   |
| `numero`  | `1`, `2`, `01`, `02`…                         |

Exemples complets : `vps-client-nbg1-1`, `vps-internal-nbg1-1`, `storage-backup-nbg1-1`.

Le nom du client n'apparaît jamais en clair dans le hostname : un VPS peut héberger plusieurs clients, et le hostname est visible dans de nombreux logs.

---

## vps-helper

`vps-helper` est une commande d'administration installée sur le serveur lors de l'initialisation.

| Commande | Description |
|---|---|
| `vps-helper status` | État du serveur (identique au message de connexion SSH) |
| `vps-helper whitelist <IP>` | Ajouter une IP de confiance (jamais bannie par fail2ban) |
| `vps-helper unban <IP>` | Débannir une IP bannie par fail2ban |
| `vps-helper close-dokploy` | Fermer l'accès direct au port 3000 (Dokploy) |
| `vps-helper restart <service>` | Redémarrer un service : `ssh`, `fail2ban`, `docker` |
| `vps-helper logs <conteneur>` | Afficher les logs d'un conteneur Docker (Ctrl+C pour quitter) |
| `vps-helper update` | Mettre à jour le système (sécurité incluse) |
| `vps-helper check` | Vérifier l'état du durcissement en lecture seule (PASS / FAIL / INFO) |
| `vps-helper version` | Afficher la version de `init-vps.sh` utilisée pour initialiser ce serveur |
| `vps-helper help` | Afficher l'aide |

### vps-helper check

Audit de lecture seule du durcissement. Vérifie :

- SSH : `PermitRootLogin no` et `PasswordAuthentication no` (via `sshd -T`, configuration effective)
- UFW : actif, politique par défaut `deny incoming`
- fail2ban : service actif, jails `sshd` et `recidive` activées
- Compte root : verrouillé
- Docker : rotation des logs configurée (`max-size` présent dans `daemon.json`)
- unattended-upgrades : service actif
- Informationnel (sans statut pass/fail) : swap, port 3000, redémarrage requis, état Docker Swarm

---

## Versioning

Chaque release correspond à un tag Git `vX.Y.Z` (semver). Le workflow CI/CD :

1. Lance les checks ShellCheck + syntaxe sur le tag
2. Injecte la version dans `SCRIPT_VERSION` du script (substitution sur une copie — la branche principale conserve `0.0.0-dev`)
3. Publie une GitHub Release avec le script versionné en asset téléchargeable

La version installée sur le serveur est accessible via `vps-helper version`.

---

## Licence

[MIT](LICENSE) — © 2026 Studio Kyne
