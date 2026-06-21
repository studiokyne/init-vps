# CLAUDE.md — init-vps

## Architecture

Ce dépôt contient **un seul fichier** : `init-vps.sh`. Il est conçu pour être installable en une seule commande `curl | bash` ou `curl -o ... && bash`. **Ne jamais le scinder en plusieurs fichiers sourcés.**

À l'exécution, `init-vps.sh` génère deux sous-scripts sur le serveur cible via des heredocs :

- **MOTD** (`/etc/update-motd.d/00-studiokyne`) — délimité par `MOTDEOF`
- **vps-helper** (`/usr/local/bin/vps-helper`) — délimité par `HELPEREOF`

Les deux heredocs utilisent des délimiteurs **entre guillemets simples** (`<<'MOTDEOF'`, `<<'HELPEREOF'`), ce qui signifie qu'aucune variable du script parent n'est interpolée à l'intérieur — à l'exception de `SCRIPT_VERSION` dans `HELPEREOF`, injectée via un `sed -i` après l'écriture du fichier.

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
awk "/^cat > \/etc\/update-motd.d\/00-studiokyne <<'MOTDEOF'/{p=1;next} /^MOTDEOF$/{p=0} p" \
  init-vps.sh > /tmp/motd_check.sh && bash -n /tmp/motd_check.sh && echo "MOTD OK"

# Extraire et tester le heredoc vps-helper
awk "/^cat > \/usr\/local\/bin\/vps-helper <<'HELPEREOF'/{p=1;next} /^HELPEREOF$/{p=0} p" \
  init-vps.sh > /tmp/helper_check.sh && bash -n /tmp/helper_check.sh && echo "vps-helper OK"
```

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
- Sur le serveur, `vps-helper version` affiche la version de `init-vps.sh` utilisée pour l'initialisation (via `INIT_VPS_VERSION` dans vps-helper, injectée par `sed -i` lors de l'étape 14).
