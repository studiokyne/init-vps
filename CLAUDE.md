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

### Rôle du serveur (`SERVER_ROLE`) — manager vs remote server

`collect_server_role()` demande, tôt dans la collecte (juste après `collect_swap`, avant les questions Dokploy), si ce serveur est :

1. `SERVER_ROLE=1` — **manager Dokploy** : héberge Dokploy + Traefik sur ce serveur. Les questions `collect_dokploy_restrict_ip`/`collect_advertise_addr` ne sont posées que dans ce cas, et `step_dokploy`/`step_traefik_tuning` s'exécutent dans `main()`.
2. `SERVER_ROLE=2` — **remote server** : géré à distance par un manager Dokploy existant (ajouté ensuite via Dokploy → Settings → Servers → Add Server). Ni Dokploy ni Traefik ne sont installés ; seul `ensure_docker` est appelé (Docker peut aussi être installé par Dokploy lui-même via SSH, mais le pré-installer ici évite l'échec connu sur les codenames trop récents, voir `ensure_docker`).

`show_recap()` et `print_summary()` adaptent leur affichage selon `SERVER_ROLE` (pas de ligne « Dokploy » pour un remote server). **Ne pas dupliquer la logique d'installation Dokploy** dans la branche remote — elle reste entièrement dans `step_dokploy`/`step_traefik_tuning`, simplement non appelées.

### Mode mise à jour (`--update` / `/etc/init-vps/config.env`)

`step_save_state()` (dernière étape, avant `print_summary`) écrit la configuration collectée dans `/etc/init-vps/config.env` (`SERVER_HOSTNAME`, `ADMIN_USER`, `TIMEZONE`, `SWAP_SIZE_GB`, `DOKPLOY_RESTRICT_IP`, `ADVERTISE_ADDR`, `SERVER_ROLE`, `SCRIPT_VERSION`, `LAST_RUN`). Les clés SSH ne sont **jamais** persistées ici — `authorized_keys` sur le serveur reste la seule source de vérité, gérée via `vps-helper ssh-keys`.

Au lancement suivant, `main()` détecte ce fichier et propose (ou force via `sudo ./init-vps.sh --update`) un **mode mise à jour** : la config est `source`-ée (aucune question reposée), puis **toutes** les étapes `step_*` sont rejouées normalement, dans le même ordre que l'installation initiale. Ce n'est volontairement pas un mécanisme séparé : comme chaque `step_*` est déjà idempotente (voir « Pattern step_* idempotent » ci-dessous), les rejouer suffit à propager tout changement apporté au script (nouveau contenu MOTD, nouvelle commande vps-helper, nouvelle règle sysctl, etc.) sans code de mise à jour dédié à maintenir en parallèle.

**Piège corrigé à ce sujet** : `step_fail2ban` écrasait entièrement `jail.local` à chaque exécution, ce qui aurait effacé la liste blanche (`ignoreip`) ajoutée via `vps-helper whitelist` lors d'une relance. La ligne `ignoreip` existante est maintenant capturée avant réécriture et réinjectée. **Si une nouvelle étape régénère un fichier par `cat > ... <<EOF`, vérifier qu'elle ne détruit pas un état modifié depuis par un utilisateur ou par vps-helper.**

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

Déclenché sur `push`, `pull_request`, et `workflow_call` (pour être appelé depuis release.yml).

- `bash -n init-vps.sh` — syntaxe du script principal
- ShellCheck en mode strict (`severity: warning`) via `ludeeus/action-shellcheck@2.0.0`
- Extraction + `bash -n` des deux heredocs (`MOTDEOF`, `HELPEREOF`)

### auto-release.yml

Déclenché sur push vers `main`. Enchaîne en un seul job : lint → calcul de version → build → publication.

Format de version : `YYYY.MM.DD.N` (N incrémental sur la journée, repart à 1 chaque jour).
Exemple : `v2026.06.21.1`, puis `v2026.06.21.2` si un second push a lieu le même jour.

L'algorithme de calcul : liste les tags `v{DATE}.*` existants via `git tag -l`, prend le N maximum, incrémente.

Aucune convention de message de commit requise — chaque push vers `main` produit une release.

### release.yml

Déclenché sur push de tag `v*.*.*` (créé par release-please ou manuellement).

1. Appelle `lint.yml` via `workflow_call` — la release échoue si le lint échoue
2. Extrait la version (`v1.2.0` → `1.2.0`) depuis le nom du tag
3. Injecte la version dans une **copie** du script (`sed` sur `SCRIPT_VERSION`) — la branche principale conserve `0.0.0-dev`
4. Publie une GitHub Release avec le script versionné comme asset `init-vps.sh`
5. Notes de version générées automatiquement

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
