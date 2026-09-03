# CLAUDE.md — init-vps

## Architecture

Ce dépôt contient **un seul fichier** : `init-vps.sh`. Il est conçu pour être installable en une seule commande `curl | bash` ou `curl -o ... && bash`. **Ne jamais le scinder en plusieurs fichiers sourcés.**

À l'exécution, `init-vps.sh` génère deux sous-scripts sur le serveur cible via des heredocs :

- **MOTD** (`/etc/update-motd.d/00-studiokyne`) — délimité par `MOTDEOF`
- **vps-helper** (`/usr/local/bin/vps-helper`) — délimité par `HELPEREOF`

Les deux heredocs utilisent des délimiteurs **entre guillemets simples** (`<<'MOTDEOF'`, `<<'HELPEREOF'`), ce qui signifie qu'aucune variable du script parent n'est interpolée à l'intérieur — à l'exception de `SCRIPT_VERSION` et `DEFAULT_ADMIN_USER` dans `HELPEREOF`, injectées via deux `sed -i` après l'écriture du fichier (voir `step_vps_helper`).

### Heredoc imbriqué `FRAGEOF` dans `HELPEREOF`

`cmd_traefik_tuning` (dans vps-helper) contient un **heredoc imbriqué** délimité par `FRAGEOF` : le YAML du middleware `compression` est écrit dans un fichier temporaire, puis fusionné dans `middlewares.yml` via `yq`. Ce bloc `FRAGEOF` est du texte littéral pour le `cat` parent (`HELPEREOF`) ; il n'est interprété qu'à l'exécution de vps-helper sur le serveur. **Ne jamais renommer `FRAGEOF` en `HELPEREOF`** (collision de délimiteurs).

### Étape 17 — Optimisation Traefik (déléguée à vps-helper)

`step_traefik_tuning()` (script parent) ne contient **aucune logique** : elle délègue à `vps-helper traefik-tuning`. C'est possible car `step_vps_helper` s'exécute **avant** `step_dokploy`/`step_traefik_tuning`, donc le binaire existe déjà. Toute la logique réelle (patch `yq` idempotent de `traefik.yml` + `dynamic/middlewares.yml`, backups horodatés, ouverture UFW UDP/443, rechargement `docker service update --force dokploy-traefik`) vit dans `cmd_traefik_tuning`. **Ne pas dupliquer cette logique dans le parent.**

Points clés :
- Le middleware s'appelle `compression` (référencé `compression@file`) — nom neutre, sans préfixe `sk-`.
- HTTP/3 = QUIC sur **UDP/443** : `step_ufw_base` ouvre `443/udp`, et `cmd_traefik_tuning` le garantit aussi (cas d'un serveur provisionné avant l'ajout de cette règle).
- Le patch utilise `yq` (mikefarah, téléchargé si absent) et un merge profond (`eval-all ... ireduce`) pour **préserver** les middlewares gérés par Dokploy (`redirect-to-https`, `addprefix-*`, etc.). Jamais de réécriture destructive.

### UFW ne filtre PAS les ports publiés par Docker (étapes 16 et 17)

Le trafic vers un conteneur traverse `FORWARD` (`DOCKER-USER`, `DOCKER-FORWARD`)
et ne passe **jamais** par les chaînes `ufw-*`. Mesuré sur un serveur réel :
102 M de paquets dans `DOCKER-USER`, **0** dans toutes les chaînes
`ufw-*forward`. Un `-p 0.0.0.0:PORT` est donc exposé à Internet même sans règle
UFW, et `ufw status` n'en dit rien. Sur le serveur diagnostiqué, la seule
protection réelle était un Hetzner Cloud Firewall — invisible depuis la machine.
**Ne jamais raisonner comme si UFW couvrait les conteneurs.**

Deux étapes distinctes en découlent, avec des rôles opposés :

- `step_docker_user_firewall` (16) — **préventive**. Remplit `DOCKER-USER` :
  RETURN sur established/related, sur 80, 443/tcp, 443/udp et les RFC1918
  entrants par l'interface publique (route par défaut), DROP sur le reste
  arrivant par cette interface, RETURN final. Persistance :
  `/usr/local/lib/docker-user/apply.sh` (idempotent, `iptables -F DOCKER-USER`
  en tête, interface redétectée à chaque exécution) + unit oneshot
  `docker-user-rules.service` (`After=docker.service`, `RemainAfterExit=yes`).
- `step_docker_ports_audit` (17) — **lecture seule**, aucun correctif : couper
  un port publié en production serait plus dangereux que de le signaler.

`docker_published_public_ports()` croise **deux** sources, dupliquée à
l'identique dans le parent et dans `HELPEREOF` : `docker ps` (préfixes
`0.0.0.0:` / `[::]:`) **et** `docker service ls` (préfixe `*:`). Aucune n'est
complète — un service Swarm publié en mode ingress n'apparaît pas dans
`docker ps` (son conteneur de tâche ne montre que ses ports internes, ex.
`3000/tcp` pour Dokploy), un conteneur hors Swarm n'apparaît que là. **Ne pas
retirer l'une des deux.** À noter : `ss -lntup | grep docker-proxy` ne remplace
ni l'une ni l'autre — avec Docker 29 (nftables direct) il ne renvoie rien.

Comportement différencié, c'est le cœur du dispositif :

| Contexte | Comportement |
|---|---|
| `UPDATE_MODE=0` | Application directe — aucun conteneur n'existe encore, rien à casser. C'est là toute la valeur : les conteneurs installés juste après (Dokploy, Traefik) naissent derrière le filtre. |
| `UPDATE_MODE=1`, chaîne vide, conteneurs publiant | Liste des ports qui seraient coupés, puis `confirm` **défaut non**. Refus → `log_warn` avec la commande à lancer plus tard. |
| `UPDATE_MODE=1`, règles déjà posées | Pas de question : les ports listés sont **déjà** bloqués, un refus ne rétablirait rien (il sauterait juste une réapplication à l'identique). `log_info` + renvoi vers `docker-firewall clear`. |
| `iptables` absent | `log_info` + retour, effectif au prochain run. |
| Règles `DOCKER-USER` tierces | `log_warn` + retour, jamais d'écrasement. |

Nos règles portent toutes `-m comment --comment init-vps` : c'est **le seul**
moyen de les distinguer de règles tierces, ne pas le retirer.

⚠️ À la première installation, Docker n'est pas encore installé quand l'étape
tourne : l'unit ne peut pas démarrer (`Requires=docker.service`), donc
`apply.sh` est **exécuté directement**. C'est sans risque — `iptables -N` crée
la chaîne, et le démon Docker ne vide jamais `DOCKER-USER` au démarrage.
Déplacer cette étape après `step_dokploy` annulerait justement sa raison d'être.

L'audit et le filtrage valent pour **les deux rôles** : un remote server héberge
aussi des conteneurs.

Côté vps-helper : `cmd_docker_firewall` (`status|apply|clear`, dans
`NEED_ROOT_CMDS`) et une section « Ports publiés par Docker » dans `cmd_check`.
`clear` est le filet de sécurité si les règles cassent un service en production.
Le heredoc `APPLYEOF` est validé par une porte dédiée dans `lint.yml`.

### `dokploy_port_is_open()` a deux sources de vérité

UFW **ou** un conteneur publiant `0.0.0.0:3000->`. Ni l'une ni l'autre ne
suffit : `$DOKPLOY_PORT_CLOSED` ignore un `ufw delete` manuel, et UFW ignore les
ports publiés par Docker. Sur le serveur diagnostiqué, `vps-helper check`
annonçait « Port 3000 : fermé » pendant que docker-proxy écoutait sur
`0.0.0.0:3000`.

### `configure_needrestart()` s'exécute avant l'étape 1

Le réglage `nrconf{restart} = 'a'` vivait dans `step_unattended_upgrades`
(étape 9), soit **après** le `dist-upgrade` de l'étape 1 : le premier run
pouvait donc se bloquer sur le menu plein écran de needrestart avant d'atteindre
la configuration censée l'éviter. La fonction est appelée depuis `main()` avant
`step_update_system`, puis **une seconde fois à la fin de `step_update_system`**
— cas d'un système où le paquet `needrestart` n'était pas encore installé lors
du premier appel (le fichier de conf n'existait pas, il n'y avait rien à régler),
alors que des paquets sont encore installés ensuite (Docker, Dokploy).

### `99-network-perf.conf` — strictement quatre clés

`step_sysctl_hardening` écrit un troisième fichier sysctl : `fq` + `bbr`,
`tcp_max_syn_backlog`, `tcp_fin_timeout`. **Ne pas y ajouter `somaxconn`,
`fs.file-max` ni `nf_conntrack_max`** : mesurés sur un serveur réel (32
conteneurs, une semaine d'uptime), ils sont déjà bons par défaut sur Ubuntu
24.04 — les reposer ne changerait rien et donnerait l'illusion d'un réglage
utile.

### Rôle du serveur (`SERVER_ROLE`) — manager vs remote server

`collect_server_role()` demande, tôt dans la collecte (juste après `collect_swap`, avant les questions Dokploy), si ce serveur est :

1. `SERVER_ROLE=1` — **manager Dokploy** : héberge Dokploy + Traefik sur ce serveur. Les questions `collect_dokploy_restrict_ip`/`collect_advertise_addr` ne sont posées que dans ce cas, et `step_dokploy`/`step_traefik_tuning` s'exécutent dans `main()`.
2. `SERVER_ROLE=2` — **remote server** : géré à distance par un manager Dokploy existant (ajouté ensuite via Dokploy → Settings → Servers → Add Server). Ni Dokploy ni Traefik ne sont installés ; seul `ensure_docker` est appelé (Docker peut aussi être installé par Dokploy lui-même via SSH, mais le pré-installer ici évite l'échec connu sur les codenames trop récents, voir `ensure_docker`).

`show_recap()` et `print_summary()` adaptent leur affichage selon `SERVER_ROLE` (pas de ligne « Dokploy » pour un remote server). **Ne pas dupliquer la logique d'installation Dokploy** dans la branche remote — elle reste entièrement dans `step_dokploy`/`step_traefik_tuning`, simplement non appelées.

### Mode mise à jour (`--update` / `/etc/init-vps/config.env`)

`step_save_state()` (dernière étape, avant `print_summary`) écrit la configuration collectée dans `/etc/init-vps/config.env` (`SERVER_HOSTNAME`, `ADMIN_USER`, `TIMEZONE`, `SWAP_SIZE_GB`, `DOKPLOY_RESTRICT_IP`, `ADVERTISE_ADDR`, `SERVER_ROLE`, `SCRIPT_VERSION`, `LAST_RUN`). Les clés SSH ne sont **jamais** persistées ici — `authorized_keys` sur le serveur reste la seule source de vérité, gérée via `vps-helper ssh-keys`.

Au lancement suivant, `main()` détecte ce fichier et propose (ou force via `sudo ./init-vps.sh --update`) un **mode mise à jour** : la config est `source`-ée (aucune question reposée), puis **toutes** les étapes `step_*` sont rejouées normalement, dans le même ordre que l'installation initiale. Ce n'est volontairement pas un mécanisme séparé : comme chaque `step_*` est déjà idempotente (voir « Pattern step_* idempotent » ci-dessous), les rejouer suffit à propager tout changement apporté au script (nouveau contenu MOTD, nouvelle commande vps-helper, nouvelle règle sysctl, etc.) sans code de mise à jour dédié à maintenir en parallèle.

**Piège corrigé à ce sujet** : `step_fail2ban` écrasait entièrement `jail.local` à chaque exécution, ce qui aurait effacé la liste blanche (`ignoreip`) ajoutée via `vps-helper whitelist` lors d'une relance. La ligne `ignoreip` existante est maintenant capturée avant réécriture et réinjectée. **Si une nouvelle étape régénère un fichier par `cat > ... <<EOF`, vérifier qu'elle ne détruit pas un état modifié depuis par un utilisateur ou par vps-helper.**

### `print_summary()` — les « prochaines étapes » sont conditionnelles

Chaque étape n'est affichée que si elle est **encore à faire**, sondée sur l'état réel :

| Étape | Condition |
|---|---|
| Vérifier la connexion SSH | `UPDATE_MODE = 0` (une relance passe déjà par SSH) |
| Pointer un domaine / configurer le TLS | `dokploy_has_tls_domain` faux |
| Fermer le port 3000 | `dokploy_port_is_open` vrai |
| Ajouter au manager | rôle remote |

Les lignes d'en-tête suivent la même règle — **elles rapportent l'état réel, pas la valeur
demandée** :

- **Swap** : lu via `free`, jamais via `$SWAP_SIZE_GB`. Cette variable vaut `0` aussi bien
  quand aucun swap n'a été voulu que lorsqu'un swap préexistant a fait sauter l'étape ;
  afficher « aucun (ou déjà présent) » revenait à avouer qu'on ne savait pas. Même raison
  pour les logs de `collect_swap` et `step_swap`.
- **Dokploy** : l'URL `http://IP:3000` n'est affichée que si le port est encore ouvert.
  Une fois fermé, annoncer cette adresse serait un lien mort.

⚠️ `collect_swap` teste **tout swap actif** (`swapon --show --noheadings`), pas seulement
`/swapfile`. Le motif d'origine ne matchait pas une **partition** de swap fournie par le
provider : le script demandait alors une taille que `step_swap`, lui correctement gardé,
ignorait ensuite.

Si rien ne reste, le résumé affiche « Aucune action requise ». Réafficher la checklist
d'une première installation à chaque relance est du bruit — et le bruit finit par faire
ignorer les vraies alertes, comme le redémarrage requis après un nouveau kernel.

- `dokploy_has_tls_domain()` lit `acme.json` (magasin de certificats Traefik, root-only)
  et cherche une clé `"main"` : chaque certificat émis y porte son domaine.
- `dokploy_port_is_open()` interroge **UFW**, pas `$DOKPLOY_PORT_CLOSED` : cette variable
  ne connaît que les fermetures faites via `vps-helper close-dokploy`, pas un `ufw delete`
  lancé à la main.
- `step_sep()` insère la ligne vide entre deux étapes, jamais avant la première — sinon la
  liste commence par un blanc dès qu'une étape amont est sautée. Elle lit `$step_n` par
  portée dynamique.

⚠️ **Le résumé — et l'avertissement de `step_ufw_base` — recommandent
`vps-helper close-dokploy`, jamais `ufw delete allow 3000/tcp`.**
Les deux ferment le port, mais seul le premier persiste le choix dans `config.env` ; un
`ufw delete` brut serait **rouvert par `step_ufw_base`** à la prochaine relance. Le résumé
conseillait la commande brute — il conseillait donc une action que le script défaisait.

---

## Conventions de code

### Helpers de log (script principal)

```bash
log_step()   # titre de section (affiché en gras bleu)
log_info()   # information neutre
log_ok()     # succès
log_warn()   # avertissement non bloquant
log_err()    # erreur (affichée sur stderr)
log_secret() # information sensible : console uniquement, jamais dans le log
error()      # log_err + exit 1
```

Tous écrivent aussi dans `$LOG_FILE` (texte brut, sans séquences ANSI).

### Pattern step_* idempotent

Chaque étape vérifie l'état actuel avant d'agir. Si l'état cible est déjà atteint, elle log et retourne immédiatement. Exemple typique :

```bash
step_xxx() {
    log_step "..."
    if <état déjà en place>; then
        log_info "Déjà configuré, rien à faire."
        return
    fi
    # … configuration …
    log_ok "Configuré."
}
```

### Prompts interactifs

- `prompt VARNAME "Question" "défaut" [validateur]` — saisie avec validation
- `confirm "Question" "o|n"` — oui/non, retourne 0 si oui

---

## Piège critique : `printf %b` / `%s` / `cat` dans les heredocs

**Ce bug est survenu deux fois en production.** Les couleurs ANSI dans les heredocs sont des chaînes littérales, par exemple `C_GREEN='\033[0;32m'`.

- `cat` **n'interprète jamais** ces séquences.
- `printf` ne les interprète que via `%b` — **jamais via `%s`**.
- Toute sortie colorée (MOTD, vps-helper, vps-helper check) doit utiliser :

```bash
# CORRECT — couleur dans un argument → %b
printf '%b %s\n' "${C_GREEN}[OK]${C_RESET}" "$message_plain"

# CORRECT — couleur dans la chaîne de format elle-même
printf "${C_GREEN}texte fixe${C_RESET}\n"

# FAUX — %s ne décodera pas \033[...
printf '%s\n' "${C_GREEN}texte${C_RESET}"
```

Pour vérifier qu'un ESC réel est généré (octet `0x1B`, affiché `^[` par `cat -v`) :

```bash
./init-vps.sh 2>/dev/null | cat -v   # ne fonctionne pas en interactif
# Tester directement le sous-script :
bash /etc/update-motd.d/00-studiokyne | cat -v
vps-helper check | cat -v
```

---

## Tester localement avant de commit

```bash
# Syntaxe du script principal
bash -n init-vps.sh

# ShellCheck strict (nécessite shellcheck installé)
shellcheck --severity=warning init-vps.sh

# Extraire et tester le heredoc MOTD
awk "/cat > \/etc\/update-motd.d\/00-studiokyne <<'MOTDEOF'/{p=1;next} /^MOTDEOF$/{p=0} p" \
  init-vps.sh > /tmp/motd_check.sh && [ -s /tmp/motd_check.sh ] && bash -n /tmp/motd_check.sh && echo "MOTD OK"

# Extraire et tester le heredoc vps-helper
awk "/cat > \/usr\/local\/bin\/vps-helper <<'HELPEREOF'/{p=1;next} /^HELPEREOF$/{p=0} p" \
  init-vps.sh > /tmp/helper_check.sh && [ -s /tmp/helper_check.sh ] && bash -n /tmp/helper_check.sh && echo "vps-helper OK"
```

⚠️ Le motif awk ne doit **pas** ancrer `cat` en début de ligne (`^cat`) : les deux heredocs sont écrits depuis l'intérieur d'une fonction (`step_motd`, `step_vps_helper`) et sont donc indentés. Un motif ancré matche 0 ligne, produit un fichier vide, et `bash -n` sur un fichier vide « réussit » silencieusement (faux positif) — c'est resté un bug non détecté dans `lint.yml` jusqu'à ce que ce soit corrigé. Le `[ -s ... ]` avant `bash -n` garde ce piège détectable si ça régresse.

---

## Workflows GitHub Actions

### lint.yml

Déclenché sur `push` (hors `main`), `pull_request`, et `workflow_call` (appelé par `auto-release.yml`).

- `bash -n init-vps.sh` — syntaxe du script principal
- ShellCheck en mode strict (`severity: warning`) via `ludeeus/action-shellcheck@2.0.0`
- Extraction + `bash -n` des deux heredocs (`MOTDEOF`, `HELPEREOF`)

### auto-release.yml

Déclenché sur push vers `main`. Deux jobs : `lint` (via `workflow_call` vers `lint.yml`) puis
`auto-release` (calcul de version → build → publication).

⚠️ **Les contrôles ne sont jamais recopiés ici — ils sont réutilisés.** La version précédente
dupliquait les étapes de `lint.yml`, et la copie avait dérivé : son motif `awk` était ancré sur
`^cat` alors que les deux heredocs sont indentés dans des fonctions. L'extraction renvoyait
0 ligne et `bash -n` sur un fichier vide réussit — le contrôle des heredocs ne testait donc
**rien**, précisément sur le chemin qui publie les releases. C'est le même piège que celui
documenté plus haut pour `lint.yml`, corrigé là-bas seulement. Toute nouvelle porte de
validation va dans `lint.yml`.

⚠️ **La substitution de version utilise `sed "0,/^SCRIPT_VERSION=.*/s//…/"`, pas un `s///`
global.** `^SCRIPT_VERSION=` matche **deux** lignes : la constante en tête de fichier, et la
ligne du heredoc de `step_save_state` qui écrit `config.env`, laquelle doit rester
`${SCRIPT_VERSION}`. Un `sed` non borné fige les deux. Un `grep -q` vérifie ensuite que la
substitution a bien eu lieu : sans lui, un motif devenu obsolète publierait un script marqué
`0.0.0-dev` en silence.

Format de version : `YYYY.MM.DD.N` (N incrémental sur la journée, repart à 1 chaque jour).
Exemple : `v2026.06.21.1`, puis `v2026.06.21.2` si un second push a lieu le même jour.

L'algorithme de calcul : liste les tags `v{DATE}.*` existants via `git tag -l`, prend le N maximum, incrémente.

Aucune convention de message de commit requise — chaque push vers `main` produit une release.

### Pas de second chemin de publication

`release.yml`, déclenché sur push de tag, a été **supprimé**. Il faisait le même travail
qu'`auto-release.yml` par une autre voie, et ne se déclenchait de toute façon jamais seul :
un tag créé par `GITHUB_TOKEN` ne relance pas de workflow.

C'est cette duplication qui avait laissé vivre un contrôle de heredocs cassé sur le chemin
de publication (voir plus haut). **Ne pas réintroduire un second workflow de release** :
toute publication passe par `auto-release.yml`, tout contrôle vit dans `lint.yml`.

---

## Versioning

- La constante `SCRIPT_VERSION="0.0.0-dev"` est présente dans le script source sur `main`.
- Un push sur `main` calcule automatiquement la version `YYYY.MM.DD.N` et la substitue dans la copie publiée.
- La version est incluse dans le résumé final (`print_summary()`) et dans le log `/var/log/init-vps.log`.

---

## Tester le heredoc imbriqué `FRAGEOF`

L'extraction du heredoc vps-helper (voir plus haut) inclut automatiquement le bloc `FRAGEOF`, puisqu'il fait partie du corps de `HELPEREOF`. Un `bash -n` sur `helper_check.sh` valide donc aussi la syntaxe de `cmd_traefik_tuning` et de son heredoc imbriqué.
- Sur le serveur, `vps-helper version` affiche la version de `init-vps.sh` utilisée pour l'initialisation (via `INIT_VPS_VERSION` dans vps-helper, injectée par `sed -i` lors de l'étape 14).

## Commande `vps-helper ssh-keys` (gestion interactive des clés SSH)

`vps-helper ssh-keys <list|add|remove> [utilisateur]` gère `authorized_keys` d'un utilisateur (par défaut `DEFAULT_ADMIN_USER`, injecté par `sed -i` comme `INIT_VPS_VERSION`, voir plus haut). Points d'attention si on la modifie :

- `resolve_ssh_user()` est appelée via `$(...)` par les commandes (`user="$(resolve_ssh_user "$1")" || exit 1`) — elle ne doit **jamais** faire `exit` en cas d'erreur (ça ne quitterait qu'un sous-shell), uniquement `return 1` après avoir loggé via `err()`.
- `cmd_ssh_keys_remove` refuse de supprimer la dernière clé restante (`${#SSH_KEYS_LINES[@]} -le 1`) pour éviter un verrouillage SSH complet.
- Chaque écriture d'`authorized_keys` (add/remove) est précédée d'un `cp -a` horodaté, comme le reste du script.
- `ssh-keys` fait partie de `NEED_ROOT_CMDS` (élévation automatique via `exec sudo "$0" "$@"`), car l'édition du `.ssh` d'un autre utilisateur que l'appelant requiert root.
