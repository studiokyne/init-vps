#!/usr/bin/env bash
###############################################################################
# init-vps.sh — Initialisation et durcissement VPS (100% interactif)
# Cible : Ubuntu / Debian (testé sur Ubuntu 24.04 LTS, sans verrou de version
#         pour rester compatible avec les futures releases LTS)
#
# USAGE (commande unique) :
#   curl -fsSL <URL_RAW_GITHUB>/init-vps.sh -o init-vps.sh \
#     && chmod +x init-vps.sh && sudo ./init-vps.sh
#
# MODE MISE À JOUR :
#   Une fois exécuté une première fois, le script sauvegarde sa configuration
#   dans /etc/init-vps/config.env. En relançant le script sur ce même serveur
#   (nouvelle version téléchargée, nouvelles fonctionnalités...), il détecte
#   ce fichier et propose un « mode mise à jour » : aucune question reposée,
#   la config est rechargée et toutes les étapes (idempotentes) sont rejouées
#   — ce qui applique automatiquement les changements (MOTD, vps-helper,
#   durcissement, etc.) sans tout réinitialiser. Forçable avec :
#     sudo ./init-vps.sh --update
#
# Le script pose toutes les questions nécessaires au fur et à mesure, avec
# une valeur par défaut entre crochets quand il y en a une (Entrée pour
# l'accepter). Chaque saisie est validée pour éviter les typos.
#
# Étapes :
#   0. Collecte interactive de la configuration (dont le rôle du serveur —
#      manager Dokploy ou remote server) + récapitulatif + confirmation
#   1. Mise à jour du système
#   2. Définition du hostname
#   3. Création du compte admin (sudo) + clé(s) SSH
#   4. fail2ban (activé AVANT l'ouverture SSH, pas de fenêtre exposée)
#   5. Durcissement SSH — phase 1 (transition, root encore actif en filet de
#      sécurité le temps de valider l'accès au compte admin)
#   6. UFW (pare-feu)
#   7. Durcissement SSH — phase 2 (verrouillage final, après confirmation
#      manuelle que la connexion admin/sudo fonctionne)
#   8. Verrouillage du compte root (défense en profondeur, en plus du SSH)
#   9. unattended-upgrades (MAJ sécurité auto, sans reboot)
#  10. Durcissement sysctl (réseau + mémoire pour Redis/Dokploy)
#  11. Swap (taille recommandée selon la RAM détectée, ajustable)
#  12. Fuseau horaire / NTP / limites des logs journald
#  13. MOTD personnalisé (design uniforme à la connexion SSH)
#  14. Commande d'aide vps-helper (whitelist, ssh-keys, restart, logs, update...)
#  15. Limitation des logs Docker (rotation 10 Mo x 3 par conteneur)
#  16. Pare-feu des ports publiés par Docker (chaîne DOCKER-USER + unit
#      systemd) — UFW ne filtre PAS ces ports ; posé avant tout conteneur à
#      l'installation, sur confirmation en mode mise à jour
#  17. Audit des ports publiés sur 0.0.0.0 (lecture seule, aucune correction
#      automatique)
#  18. Installation de Dokploy — uniquement si rôle = manager
#  19. Optimisation Traefik (HTTP/3 + compression Brotli/Zstd, patch idempotent)
#      — uniquement si rôle = manager
#  20. Notifications (webhook Discord/Slack, optionnel) : échecs de
#      « vps-helper check » ou d'unattended-upgrades
#  21. Sauvegarde de la configuration (/etc/init-vps/config.env), pour permettre
#      une future relance en mode mise à jour
#  22. Redémarrage automatique nocturne si requis (optionnel) : annoncé, reportable,
#      services vérifiés au retour — après l'étape 21, dont il lit la config
#
# (needrestart est réglé en mode automatique avant l'étape 1, pour qu'aucun
#  prompt interactif n'interrompe le dist-upgrade.)
#
# Résumé final + prochaines étapes, affiché et sauvegardé dans un fichier.
#
# ⚠️ Exécuter en root (sudo), sur un serveur fraîchement installé.
# ⚠️ Le verrouillage SSH (phase 2) attend une confirmation manuelle : tester
#    la connexion avec le compte admin dans un AUTRE terminal avant de valider.
###############################################################################

set -euo pipefail

###############################################################################
# CONSTANTES
###############################################################################
SCRIPT_VERSION="0.0.0-dev"
LOG_FILE="/var/log/init-vps.log"
SSHD_HARDENING_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"
STATE_DIR="/etc/init-vps"
STATE_FILE="${STATE_DIR}/config.env"
# Secret (URL du webhook) — fichier root-only (600), JAMAIS $STATE_FILE ni $LOG_FILE.
NOTIFY_ENV_FILE="${STATE_DIR}/notify.env"

# Variables collectées de façon interactive (valeurs par défaut ci-dessous)
SERVER_HOSTNAME=""
ADMIN_USER=""
SSH_PUBLIC_KEYS=()
TIMEZONE=""
SWAP_SIZE_GB=0
DOKPLOY_RESTRICT_IP=""
ADVERTISE_ADDR=""
SERVER_ROLE=""
DOKPLOY_PORT_CLOSED=""
# Port SSH : 22 par défaut, ajustable (réduit le bruit des scans, pas une
# mesure de sécurité en soi).
SSH_PORT=22
# Options ajoutées après coup. Vide = « question jamais posée » : en mode mise
# à jour, seules ces questions-là sont posées (voir ask_new_options).
NOTIFY_ENABLED=""
AUTO_REBOOT=""
AUTO_REBOOT_TIME="04:00"
# Secret saisi pendant la collecte : en mémoire uniquement, écrit dans son
# fichier 600 par step_notify, jamais dans $STATE_FILE.
NOTIFY_WEBHOOK_URL=""
PASSWORD_FILE=""
SERVER_IP=""
SUMMARY_FILE=""
# Renseigné par main() une fois le mode résolu. print_summary() s'en sert pour
# n'afficher que les actions encore pertinentes : sur une relance, les
# « prochaines étapes » d'une première installation sont du bruit.
UPDATE_MODE=0

###############################################################################
# STYLE — couleurs sobres, désactivées si la sortie n'est pas un terminal
###############################################################################
if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_BOLD='\033[1m'
    C_BLUE='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'; C_DIM='\033[2m'
else
    C_RESET=''; C_BOLD=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi

###############################################################################
# LOGGING — couleur en console, texte brut dans le fichier de log
###############################################################################
log_info() { echo -e "${C_DIM}[i]${C_RESET} $*"; echo "[i] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; echo "[OK] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; echo "[!] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_err()  { echo -e "${C_RED}[x]${C_RESET} $*" >&2; echo "[x] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_step() { echo -e "\n${C_BOLD}${C_BLUE}▶ $*${C_RESET}"; echo -e "\n== $* ==" >> "$LOG_FILE" 2>/dev/null || true; }
# log_secret : affiche une information sensible (mot de passe...) UNIQUEMENT
# dans le terminal. Ne l'écrit JAMAIS dans le fichier de log persistant
# (sinon le mot de passe survit même après le shred du fichier dédié).
log_secret() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; echo "[!] (valeur sensible masquée dans le log)" >> "$LOG_FILE" 2>/dev/null || true; }
error()    { log_err "$*"; exit 1; }

trap 'log_err "Échec inattendu (ligne ${LINENO}) : ${BASH_COMMAND}"; exit 1' ERR

###############################################################################
# PRÉ-VÉRIFICATIONS
###############################################################################
precheck_root() {
    [[ $EUID -eq 0 ]] || { echo "Ce script doit être exécuté en root (sudo ./init-vps.sh)." >&2; exit 1; }
}

# Permet de rester interactif même si le script est exécuté via
# `curl ... | bash` (stdin = le flux du script, pas le clavier).
precheck_tty() {
    if [[ ! -t 0 ]]; then
        if [[ -e /dev/tty ]]; then
            exec < /dev/tty
        else
            echo "Entrée interactive impossible (pas de TTY disponible)." >&2
            echo "Télécharge le script puis exécute-le directement au lieu de le piper :" >&2
            echo "  curl -fsSL <URL> -o init-vps.sh && chmod +x init-vps.sh && sudo ./init-vps.sh" >&2
            exit 1
        fi
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        local pretty="${PRETTY_NAME:-inconnu}"
        if [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]]; then
            log_info "Distribution détectée : ${pretty}"
        else
            log_warn "Distribution détectée : ${pretty} — ce script cible Ubuntu/Debian, il peut fonctionner ailleurs mais n'a pas été testé."
        fi
    else
        log_warn "Impossible de détecter la distribution (/etc/os-release absent)."
    fi
}

###############################################################################
# HELPERS — sauvegarde, test de config SSH
###############################################################################
# Sauvegarde un fichier hors de son répertoire d'origine, sous
# /var/backups/init-vps/, en préservant le chemin absolu. Écrire le .bak à côté
# de l'original casse les répertoires scannés en entier (ex. /etc/apt/apt.conf.d
# où apt râle « invalid filename extension » à chaque update).
backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local ts dest
    ts="$(date +%Y%m%d%H%M%S)"
    dest="/var/backups/init-vps${f}.bak-${ts}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$f" "$dest"
    return 0
}

test_sshd_config() {
    if ! sshd -t 2>/tmp/init-vps-sshd-test.err; then
        log_err "Configuration SSH invalide, redémarrage annulé (ancienne config conservée) :"
        cat /tmp/init-vps-sshd-test.err >&2
        cat /tmp/init-vps-sshd-test.err >> "$LOG_FILE" 2>/dev/null || true
        exit 1
    fi
}

###############################################################################
# HELPERS — validateurs de saisie
###############################################################################
is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.' octs o
    read -r -a octs <<< "$ip"
    for o in "${octs[@]}"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

validate_username() {
    local u="$1"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [[ "$u" != "root" ]]
}

validate_hostname() {
    local h="$1"
    # Lettres minuscules, chiffres, tirets — pas de tiret en début/fin, 63 car. max (RFC1123)
    [[ "$h" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

validate_hostname_part() {
    # Un segment du hostname (type / objectif / zone) : alphanumérique seul,
    # sans tiret (le tiret sert uniquement de séparateur entre segments).
    local v="$1"
    [[ "$v" =~ ^[a-z0-9]{1,20}$ ]]
}

# NOTE : dupliquée à l'identique dans HELPEREOF (voir validate_ssh_pubkey()
# dans vps-helper, utilisée par `ssh-keys add`) — les heredocs sont en
# guillemets simples, aucune fonction ne peut être partagée entre ce script
# et vps-helper. Garder les deux regex synchronisées en cas de modification.
validate_ssh_pubkey() {
    local key="$1"
    [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]
}

validate_timezone() {
    [[ -f "/usr/share/zoneinfo/$1" ]]
}

validate_nonneg_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_server_role() {
    [[ "$1" =~ ^[12]$ ]]
}

validate_ip_cidr() {
    local val="$1"
    [[ -z "$val" ]] && return 0
    if [[ "$val" == */* ]]; then
        local addr="${val%%/*}" mask="${val##*/}"
        is_valid_ipv4 "$addr" || return 1
        [[ "$mask" =~ ^[0-9]{1,2}$ ]] && (( mask <= 32 )) || return 1
        return 0
    fi
    is_valid_ipv4 "$val"
}

validate_ip_loose() {
    local val="$1"
    [[ -z "$val" ]] && return 0
    is_valid_ipv4 "$val" && return 0
    [[ "$val" == *:* ]] && return 0
    return 1
}

validate_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# 80/443 (Traefik) et 3000 (Dokploy) sont déjà pris sur ce serveur.
validate_ssh_port() {
    validate_port "$1" && [[ "$1" != 80 && "$1" != 443 && "$1" != 3000 ]]
}

validate_https_url() {
    [[ "$1" =~ ^https://[^[:space:]]+$ ]]
}

validate_hhmm() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

###############################################################################
# HELPERS — prompts interactifs
###############################################################################
# prompt VARNAME "Question" "valeur_par_defaut" [fonction_de_validation]
prompt() {
    local __var="$1" __question="$2" __default="${3:-}" __validator="${4:-}"
    local __input
    while true; do
        if [[ -n "$__default" ]]; then
            read -rp "$(printf '%b' "${C_BLUE}?${C_RESET} ${__question} ${C_DIM}[${__default}]${C_RESET} : ")" __input
            __input="${__input:-$__default}"
        else
            read -rp "$(printf '%b' "${C_BLUE}?${C_RESET} ${__question} : ")" __input
        fi
        if [[ -n "$__validator" ]] && ! "$__validator" "$__input"; then
            log_err "Valeur invalide pour « ${__question} », réessaie."
            continue
        fi
        printf -v "$__var" '%s' "$__input"
        break
    done
}

# confirm "Question" "o|n (défaut)"
confirm() {
    local __question="$1" __default="${2:-n}" __hint="o/N" __input
    [[ "$__default" == "o" ]] && __hint="O/n"
    read -rp "$(printf '%b' "${C_BLUE}?${C_RESET} ${__question} [${__hint}] : ")" __input
    __input="${__input:-$__default}"
    [[ "${__input,,}" =~ ^(o|oui|y|yes)$ ]]
}

# prompt_secret VARNAME "Question" [fonction_de_validation]
# Saisie masquée (read -s). Sans validateur, une valeur vide est refusée ;
# avec, c'est le validateur qui décide. La valeur n'est jamais réaffichée ni
# journalisée — y compris dans le message d'erreur.
prompt_secret() {
    local __var="$1" __question="$2" __validator="${3:-}"
    local __input
    while true; do
        read -rsp "$(printf '%b' "${C_BLUE}?${C_RESET} ${__question} ${C_DIM}(saisie masquée)${C_RESET} : ")" __input
        echo ""
        if [[ -n "$__validator" ]]; then
            if ! "$__validator" "$__input"; then
                log_err "Valeur invalide pour « ${__question} », réessaie."
                continue
            fi
        elif [[ -z "$__input" ]]; then
            log_err "Valeur vide pour « ${__question} », réessaie."
            continue
        fi
        printf -v "$__var" '%s' "$__input"
        break
    done
}

# La clé figure-t-elle dans $STATE_FILE ? Distingue « option jamais proposée »
# (serveur provisionné par une version antérieure du script) de « refusée ».
state_has() {
    [[ -f "$STATE_FILE" ]] && grep -q "^${1}=" "$STATE_FILE" 2>/dev/null
}

print_banner() {
    cat <<'EOF'

  ┌──────────────────────────────────────────────────┐
  │   INIT-VPS — Initialisation & durcissement VPS    │
  │   Ubuntu / Debian · prêt pour Dokploy             │
  └──────────────────────────────────────────────────┘

EOF
}

###############################################################################
# COLLECTE INTERACTIVE DE LA CONFIGURATION
###############################################################################
collect_hostname() {
    log_step "Nom du serveur (hostname)"
    log_info "Format : type-objectif-zone-numero (pas de nom de client en clair, un VPS peut en héberger plusieurs)."

    local host_type="vps" host_purpose="client" host_zone="nbg1" host_number="1"

    while true; do
        log_info "Type — exemples : vps, bare, nas, vm"
        prompt host_type "Type de serveur" "$host_type" validate_hostname_part

        log_info "Objectif — exemples : client, internal, backup, storage"
        prompt host_purpose "Objectif du serveur" "$host_purpose" validate_hostname_part

        log_info "Zone — exemples : nbg1, hel1, fsn1 (datacenter), ou code provider personnalisé"
        prompt host_zone "Zone / datacenter" "$host_zone" validate_hostname_part

        log_info "Numéro — un chiffre simple suffit (1, 2, 3...) ; passer à 2 chiffres (01, 02...) au-delà de 9 serveurs sur cette combinaison."
        prompt host_number "Numéro" "$host_number" validate_nonneg_int

        SERVER_HOSTNAME="${host_type}-${host_purpose}-${host_zone}-${host_number}"

        echo ""
        log_info "Hostname généré : ${C_BOLD}${SERVER_HOSTNAME}${C_RESET}"
        if ! validate_hostname "$SERVER_HOSTNAME"; then
            log_err "Format final invalide, nouvelle saisie requise."
            echo ""
            continue
        fi

        if confirm "Valider ce hostname ?" "o"; then
            break
        fi
        log_info "Nouvelle saisie (Entrée pour conserver la valeur précédente à chaque étape)."
        echo ""
    done
}

collect_admin_user() {
    log_step "Compte administrateur"
    prompt ADMIN_USER "Nom du compte admin (sudo)" "admin" validate_username
}

collect_ssh_keys() {
    log_step "Clé(s) SSH publique(s)"
    log_info "Coller le contenu de la clé publique (fichier .pub, pas le chemin)."
    SSH_PUBLIC_KEYS=()
    local key
    while true; do
        prompt key "Clé SSH publique" "" validate_ssh_pubkey
        SSH_PUBLIC_KEYS+=("$key")
        confirm "Ajouter une autre clé SSH (autre machine, collègue...)" "n" || break
    done
}

detect_ram_gb() {
    local ram
    ram=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
    (( ram < 1 )) && ram=1
    echo "$ram"
}

recommend_swap_gb() {
    local ram=$1
    if (( ram <= 2 )); then
        echo $(( ram * 2 ))
    elif (( ram <= 8 )); then
        echo "$ram"
    else
        echo 4
    fi
}

collect_swap() {
    log_step "Swap"
    # Même test que step_swap : tout swap actif, pas seulement /swapfile. Un
    # provider qui fournit une PARTITION de swap ne matchait pas ce motif, et
    # le script demandait une taille... que step_swap ignorait ensuite.
    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        log_info "Un swap est déjà actif sur ce serveur ($(free -h | awk '/^Swap:/ {print $2}')), cette étape sera ignorée."
        SWAP_SIZE_GB=0
        return
    fi
    local ram recommended
    ram=$(detect_ram_gb)
    recommended=$(recommend_swap_gb "$ram")
    log_info "RAM détectée : ${ram} Go."
    prompt SWAP_SIZE_GB "Taille du swap à créer en Go (0 pour ne pas en créer)" "$recommended" validate_nonneg_int
}

collect_server_role() {
    log_step "Rôle de ce serveur"
    log_info "1) Manager Dokploy — panel central, héberge Dokploy + Traefik sur ce serveur."
    log_info "2) Remote server — géré à distance par un manager Dokploy existant (ajouté ensuite via Dokploy → Settings → Servers → Add Server)."
    local role="${SERVER_ROLE:-1}"
    prompt role "Rôle de ce serveur (1 ou 2)" "$role" validate_server_role
    SERVER_ROLE="$role"
}

collect_dokploy_restrict_ip() {
    log_step "Accès à l'interface Dokploy (port 3000)"
    log_info "Le port 3000 sera ouvert, le temps de configurer un nom de domaine + TLS dans Dokploy (fermeture manuelle ensuite)."
    prompt DOKPLOY_RESTRICT_IP "Restreindre cet accès à une IP/CIDR précise (vide = ouvert à tous temporairement)" "" validate_ip_cidr
}

collect_advertise_addr() {
    log_step "Adresse IP pour Docker Swarm"
    local detected_public detected_local suggested
    detected_public=$(curl -s -4 --max-time 3 ifconfig.me || echo "")
    detected_local=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1 || echo "")
    suggested="${detected_public:-$detected_local}"

    if [[ -n "$detected_public" ]]; then
        log_info "IP publique détectée : ${detected_public}"
    fi
    if [[ -n "$detected_local" && "$detected_local" != "$detected_public" ]]; then
        log_warn "IP réseau locale détectée : ${detected_local} (différente de la publique — probablement un réseau privé en plus, courant chez certains hébergeurs)."
    fi
    if [[ -z "$suggested" ]]; then
        log_warn "Aucune IP détectée automatiquement, saisie manuelle requise."
    fi

    log_info "Cette adresse sera annoncée par Docker Swarm. En cas de doute, conserver l'IP publique suggérée."
    prompt ADVERTISE_ADDR "Adresse IP à utiliser pour Docker Swarm (confirme ou corrige)" "$suggested" validate_ip_loose
}

collect_timezone() {
    log_step "Fuseau horaire"
    prompt TIMEZONE "Fuseau horaire (format Region/Ville)" "Europe/Paris" validate_timezone
}

collect_ssh_port() {
    log_step "Port SSH"
    log_info "22 recommandé : rien à retenir, et certains outils ne permettent pas de changer le port SSH. Un autre port ne protège de rien en soi (un scan le retrouve), il réduit seulement le bruit des robots et la charge de fail2ban."
    # Défaut 22, sauf si sshd écoute déjà ailleurs (port changé exprès) : on ne
    # propose pas de défaire un choix existant par un simple appui sur Entrée.
    local -a current=()
    local default_port=22
    mapfile -t current < <(ssh_current_ports)
    if [[ "${#current[@]}" -gt 0 && " ${current[*]} " != *" 22 "* ]]; then
        default_port="${current[0]}"
    fi
    prompt SSH_PORT "Port SSH (Entrée = ${default_port})" "$default_port" validate_ssh_port
    if [[ "$SSH_PORT" != "22" ]]; then
        log_warn "Si un pare-feu EXTERNE filtre ce serveur (Hetzner Cloud Firewall, security group…), y autoriser ${SSH_PORT}/tcp AVANT de valider le verrouillage : il est invisible d'ici, et l'oublier coupe l'accès."
    fi
}

collect_notify() {
    log_step "Notifications (optionnel)"
    log_info "Webhook Discord ou Slack, appelé sur : échec de « vps-helper check » (OOM, disque plein, service en échec, reboot en attente…), d'unattended-upgrades, et cycle du redémarrage automatique."
    log_info "Un même webhook peut servir tous les serveurs : chaque message porte le nom, le rôle et l'IP du serveur. Seuls les problèmes notifient, le reste arrive en silencieux. Changer d'URL plus tard : sudo vps-helper notify-set"
    if [[ -f "$NOTIFY_ENV_FILE" ]]; then
        NOTIFY_ENABLED="1"
        log_info "Webhook déjà configuré (${NOTIFY_ENV_FILE}) : conservé."
        return
    fi
    if ! confirm "Configurer un webhook de notification ?" "n"; then
        NOTIFY_ENABLED="0"
        return
    fi
    NOTIFY_ENABLED="1"
    prompt_secret NOTIFY_WEBHOOK_URL "URL du webhook (https://…)" validate_https_url
}

collect_auto_reboot() {
    log_step "Redémarrage automatique (optionnel)"
    log_info "unattended-upgrades installe les correctifs de sécurité chaque jour, mais un nouveau kernel ne s'applique qu'au redémarrage."
    log_info "Si activé : un redémarrage requis est annoncé, puis effectué dans la fenêtre nocturne suivante, au moins 12 h plus tard (report : vps-helper reboot-skip). Coupure de 1 à 3 min, conteneurs compris ; au retour, les services sont vérifiés."
    log_info "Plusieurs serveurs : décaler les fenêtres (ex. manager 04:00, remotes 04:30) évite de tout couper en même temps."
    if [[ "$NOTIFY_ENABLED" != "1" ]]; then
        log_warn "Sans notifications, aucune annonce : seuls le MOTD et « vps-helper reboot-status » indiquent le redémarrage planifié."
    fi
    if ! confirm "Activer le redémarrage automatique nocturne quand il est requis ?" "o"; then
        AUTO_REBOOT="0"
        return
    fi
    AUTO_REBOOT="1"
    prompt AUTO_REBOOT_TIME "Heure de la fenêtre (HH:MM)" "${AUTO_REBOOT_TIME:-04:00}" validate_hhmm
}

show_recap() {
    log_step "Récapitulatif avant exécution"
    local swap_line dokploy_line advertise_line role_line
    [[ "$SWAP_SIZE_GB" -eq 0 ]] && swap_line="aucun" || swap_line="${SWAP_SIZE_GB} Go"
    [[ "$SERVER_ROLE" == "1" ]] && role_line="Manager Dokploy" || role_line="Remote server (géré à distance)"

    {
        echo "  Hostname                  : ${SERVER_HOSTNAME}"
        echo "  Compte admin              : ${ADMIN_USER}"
        echo "  Clé(s) SSH                : ${#SSH_PUBLIC_KEYS[@]} clé(s) fournie(s)"
        echo "  Port SSH                  : ${SSH_PORT}"
        echo "  Fuseau horaire             : ${TIMEZONE}"
        echo "  Swap                      : ${swap_line}"
        echo "  Rôle du serveur           : ${role_line}"
        if [[ "$SERVER_ROLE" == "1" ]]; then
            [[ -n "$DOKPLOY_RESTRICT_IP" ]] && dokploy_line="restreint à ${DOKPLOY_RESTRICT_IP}" || dokploy_line="ouvert temporairement à tous"
            [[ -n "$ADVERTISE_ADDR" ]] && advertise_line="${ADVERTISE_ADDR}" || advertise_line="auto-détection (Dokploy)"
            echo "  Accès Dokploy (port 3000) : ${dokploy_line}"
            echo "  Adresse Docker Swarm       : ${advertise_line}"
        fi
        if [[ "$NOTIFY_ENABLED" == "1" ]]; then
            echo "  Notifications             : webhook"
        fi
        if [[ "$AUTO_REBOOT" == "1" ]]; then
            echo "  Redémarrage automatique   : si requis, vers ${AUTO_REBOOT_TIME}"
        fi
    }
    echo ""
}

###############################################################################
# HELPERS — exécution
###############################################################################
# Renseigne SERVER_IP indépendamment du rôle (Dokploy ou non), pour que
# print_summary() et step_save_state() disposent toujours d'une IP correcte.
# Reprend le repli IP locale de step_dokploy (hostname -I) : sans lui, un
# échec transitoire de curl sur un rôle "remote" (qui n'a pas d'ADVERTISE_ADDR
# collecté) affichait littéralement le texte "<IP_DU_SERVEUR>" dans le résumé.
detect_server_ip() {
    SERVER_IP=$(curl -s -4 --max-time 3 ifconfig.me || true)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1 || true)
    fi
    # IMPORTANT : if/fi, jamais un `[[ cond ]] && affectation` en dernière
    # instruction de la fonction. Quand SERVER_IP est déjà non vide (le cas
    # normal), `[[ -z "$SERVER_IP" ]]` est faux → si c'est la DERNIÈRE
    # commande de la fonction, son statut de sortie (1) devient celui de la
    # fonction entière. Appelée en instruction nue dans main(), ça déclenche
    # `set -e` et tue tout le script sans rien afficher (bug vécu en prod).
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="${ADVERTISE_ADDR:-<IP_DU_SERVEUR>}"
    fi
}

###############################################################################
# needrestart — AVANT toute installation de paquets
###############################################################################
# Sur Ubuntu, needrestart interrompt apt avec un menu plein écran demandant
# quels services redémarrer. Ce réglage vivait dans step_unattended_upgrades
# (étape 9), soit APRÈS le dist-upgrade de l'étape 1 : le premier run pouvait
# donc se bloquer sur ce prompt avant même d'avoir atteint la configuration
# censée l'éviter. Appelée depuis main() avant step_update_system.
# Idempotente : le fichier est corrigé s'il existe, la ligne ajoutée sinon —
# rejouer en mode mise à jour ne duplique rien.
configure_needrestart() {
    local conf=/etc/needrestart/needrestart.conf
    if [[ ! -f "$conf" ]]; then
        # Pas encore installé (le paquet fait partie de step_update_system) :
        # rien à régler, et rien à interrompre non plus.
        return 0
    fi
    if grep -q "nrconf{restart}" "$conf" 2>/dev/null; then
        sed -i "s/.*nrconf{restart}.*/\$nrconf{restart} = 'a';/" "$conf"
    else
        echo "\$nrconf{restart} = 'a';" >> "$conf"
    fi
    log_info "needrestart en mode automatique (pas de prompt interactif pendant apt)."
}

###############################################################################
# 1. MISE À JOUR SYSTÈME
###############################################################################
step_update_system() {
    log_step "Mise à jour du système et installation des paquets de base"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get dist-upgrade -y
    apt-get install -y curl wget gnupg ca-certificates software-properties-common \
        ufw fail2ban unattended-upgrades update-notifier-common needrestart htop openssl
    # Cas d'un système où needrestart n'était pas installé : main() l'a appelée
    # avant, sans fichier à régler. On rattrape ici, avant l'autoremove et les
    # étapes suivantes qui installent encore des paquets (Docker, Dokploy).
    configure_needrestart
    apt-get autoremove --purge -y
    log_ok "Système à jour."
}

###############################################################################
# 2. HOSTNAME
###############################################################################
step_hostname() {
    log_step "Application du hostname"
    hostnamectl set-hostname "$SERVER_HOSTNAME"
    if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
        sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${SERVER_HOSTNAME}/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$SERVER_HOSTNAME" >> /etc/hosts
    fi
    log_ok "Hostname défini sur ${SERVER_HOSTNAME}."
}

###############################################################################
# 3. CRÉATION DU COMPTE ADMIN
###############################################################################
step_create_admin() {
    log_step "Création du compte admin"
    if id "$ADMIN_USER" &>/dev/null; then
        log_info "L'utilisateur ${ADMIN_USER} existe déjà, création de compte ignorée."
    else
        local group_opt=()
        if getent group "$ADMIN_USER" &>/dev/null; then
            log_warn "Un groupe « ${ADMIN_USER} » existe déjà sur ce système, réutilisation comme groupe principal."
            group_opt=(-g "$ADMIN_USER")
        fi
        useradd -m -s /bin/bash "${group_opt[@]}" "$ADMIN_USER"
        usermod -aG sudo "$ADMIN_USER"

        local pw
        pw=$(openssl rand -base64 18)
        echo "${ADMIN_USER}:${pw}" | chpasswd
        PASSWORD_FILE="/root/${ADMIN_USER}_password.txt"
        echo "$pw" > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        log_warn "Mot de passe sudo généré → ${PASSWORD_FILE} (affiché aussi à l'étape de validation SSH)."
    fi

    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh"
    local authorized_keys="/home/${ADMIN_USER}/.ssh/authorized_keys"
    # En mode mise à jour, SSH_PUBLIC_KEYS est vide (gestion déléguée à
    # `vps-helper ssh-keys`) : pas de nouvelle clé à fusionner, on laisse
    # authorized_keys intact plutôt que de le réécrire pour rien à chaque run.
    if [[ "${#SSH_PUBLIC_KEYS[@]}" -gt 0 ]]; then
        backup_file "$authorized_keys"
        { [[ -f "$authorized_keys" ]] && cat "$authorized_keys"; printf '%s\n' "${SSH_PUBLIC_KEYS[@]}"; } \
            | awk 'NF && !seen[$0]++' > "${authorized_keys}.tmp"
        mv "${authorized_keys}.tmp" "$authorized_keys"
        chmod 600 "$authorized_keys"
        chown "${ADMIN_USER}:${ADMIN_USER}" "$authorized_keys"
        log_ok "${#SSH_PUBLIC_KEYS[@]} clé(s) SSH fournie(s) fusionnée(s) dans authorized_keys pour ${ADMIN_USER}."
    else
        log_info "Aucune nouvelle clé SSH à fusionner (gestion : vps-helper ssh-keys)."
    fi
}

###############################################################################
# 4. FAIL2BAN — configuré et démarré AVANT l'ouverture SSH
###############################################################################
step_fail2ban() {
    log_step "Configuration de fail2ban"
    # Préserve la liste blanche (ignoreip) éventuellement ajoutée via
    # `vps-helper whitelist` avant de régénérer le fichier — sinon une
    # relance du script (mode mise à jour) l'effacerait silencieusement.
    local existing_ignoreip=""
    if [[ -f /etc/fail2ban/jail.local ]]; then
        existing_ignoreip="$(grep '^ignoreip' /etc/fail2ban/jail.local 2>/dev/null || true)"
    fi
    backup_file /etc/fail2ban/jail.local
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 4
backend  = systemd
EOF
    if [[ -n "$existing_ignoreip" ]]; then
        echo "$existing_ignoreip" >> /etc/fail2ban/jail.local
        log_info "Liste blanche fail2ban existante conservée."
    fi
    cat >> /etc/fail2ban/jail.local <<EOF

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 4
bantime  = 1h

[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 3
# recidive lit les bans que fail2ban écrit dans SON fichier de log. Sans ces
# deux lignes, elle hérite du « backend = systemd » de [DEFAULT] et cherche
# dans le journal systemd, où ces lignes n'existent pas : mesuré en production,
# 1481 échecs et 18 bans sur sshd, « Total failed: 0 » sur recidive depuis
# l'installation. Jail active, mais aveugle.
backend  = auto
logpath  = /var/log/fail2ban.log
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    log_ok "fail2ban actif (protection anti-bruteforce SSH + bannissement prolongé des récidivistes)."
}

###############################################################################
# 5. DURCISSEMENT SSH — PHASE 1 (transition sécurisée)
###############################################################################
ssh_already_hardened() {
    [[ -f "$SSHD_HARDENING_FILE" ]] && grep -q '^PermitRootLogin no' "$SSHD_HARDENING_FILE" 2>/dev/null
}

# Ports sur lesquels sshd est configuré pour écouter (config effective).
ssh_current_ports() {
    command -v sshd &>/dev/null || return 0
    sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un
}

# Lignes « Port N » pour les ports passés en arguments, dédoublonnées. Port
# est cumulatif dans sshd_config : plusieurs lignes = écoute sur chacun.
ssh_port_directives() {
    printf '%s\n' "$@" | awk 'NF && !seen[$0]++ {print "Port " $0}'
}

ssh_listening_on() {
    ss -Hltn "( sport = :${1} )" 2>/dev/null | grep -q .
}

# Commande de test à afficher, avec -p seulement si le port n'est pas 22.
ssh_cmd_hint() {
    local host="$1"
    if [[ "$SSH_PORT" == "22" ]]; then
        echo "ssh ${ADMIN_USER}@${host}"
    else
        echo "ssh -p ${SSH_PORT} ${ADMIN_USER}@${host}"
    fi
}

# Redémarre sshd, puis vérifie qu'il écoute sur chaque port attendu ($@).
# Retourne 1 sinon — à l'appelant de décider (annuler une migration, avertir).
ssh_restart() {
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        # Ubuntu 24.04 : sshd est activé par socket, et un générateur systemd
        # traduit les « Port » de sshd_config en adresses d'écoute de
        # ssh.socket — au daemon-reload seulement. Un `restart ssh` seul
        # garderait l'ancien port. ssh.service est arrêté d'abord : systemd
        # refuse de (re)démarrer un socket dont le service tourne. Les sessions
        # ouvertes survivent (KillMode=process), comme lors d'un restart classique.
        systemctl daemon-reload
        systemctl stop ssh.service >/dev/null 2>&1 || true
        systemctl restart ssh.socket
        systemctl start ssh.service >/dev/null 2>&1 || true
    else
        systemctl restart ssh
    fi
    local p missing=()
    for p in "$@"; do
        ssh_listening_on "$p" || missing+=("$p")
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        log_warn "sshd n'écoute pas sur : ${missing[*]}/tcp."
        return 1
    fi
    return 0
}

# Supprime les règles UFW SSH (commentaire « SSH (… ») d'un autre port que
# $SSH_PORT. Renumérotation à chaque suppression : on relit à chaque tour.
ssh_close_old_ports() {
    local attempts=0 line num
    while (( attempts < 20 )); do
        line="$(ufw status numbered 2>/dev/null | grep -E '# SSH \(' \
            | grep -vE "^\[ *[0-9]+\] ${SSH_PORT}/tcp[[:space:]]" | head -n1 || true)"
        [[ -z "$line" ]] && break
        num="$(grep -oP '^\[\s*\K[0-9]+' <<< "$line" || true)"
        [[ -z "$num" ]] && break
        yes | ufw delete "$num" >/dev/null 2>&1 || true
        attempts=$((attempts+1))
    done
}

# Écrit la configuration SSH verrouillée, écoutant sur les ports passés en
# arguments. Partagée par la phase 2 et la migration de port.
write_sshd_final_config() {
    cat > "$SSHD_HARDENING_FILE" <<EOF
$(ssh_port_directives "$@")
PubkeyAuthentication yes
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers ${ADMIN_USER}
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2

# Algorithmes modernes uniquement
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF
}

# Changement de port sur un serveur DÉJÀ verrouillé (mode mise à jour). Même
# principe que les phases 1/2 : écoute sur l'ancien ET le nouveau port, test
# manuel dans un autre terminal, puis fermeture de l'ancien. Un refus ne quitte
# pas le script : il revient à l'ancien port.
ssh_port_migration() {
    local -a current=() old=()
    local p
    mapfile -t current < <(ssh_current_ports)
    for p in "${current[@]}"; do
        [[ "$p" == "$SSH_PORT" ]] || old+=("$p")
    done
    if [[ "${#old[@]}" -eq 0 ]]; then
        log_info "SSH déjà verrouillé, rien à faire."
        return
    fi

    log_warn "Changement de port SSH : ${old[*]} → ${SSH_PORT}."
    backup_file "$SSHD_HARDENING_FILE"
    write_sshd_final_config "${old[@]}" "$SSH_PORT"
    test_sshd_config
    if ! ssh_restart "${old[@]}" "$SSH_PORT"; then
        log_warn "Le nouveau port n'est pas en écoute : migration annulée."
        write_sshd_final_config "${old[@]}"
        test_sshd_config
        ssh_restart "${old[@]}" || true
        ssh_revert_port "${old[@]}"
        return
    fi

    echo ""
    log_warn "=== VALIDATION DU NOUVEAU PORT SSH ==="
    echo "Ouvrir un NOUVEAU terminal (sans fermer celui-ci) et tester :"
    echo ""
    echo -e "    ${C_GREEN}$(ssh_cmd_hint "$SERVER_IP")${C_RESET}"
    echo ""
    log_warn "Pare-feu externe (Hetzner Cloud Firewall…) : ${SSH_PORT}/tcp doit y être autorisé, sinon ce test échouera."
    if confirm "La connexion sur le port ${SSH_PORT} fonctionne, fermer l'ancien port (${old[*]}) ?" "n"; then
        write_sshd_final_config "$SSH_PORT"
        test_sshd_config
        ssh_restart "$SSH_PORT" || log_warn "Vérifier l'écoute de sshd : ss -ltnp | grep sshd"
        ssh_close_old_ports
        log_ok "SSH migré sur le port ${SSH_PORT} (ancien port fermé dans UFW)."
    else
        write_sshd_final_config "${old[@]}"
        test_sshd_config
        ssh_restart "${old[@]}" || true
        ssh_revert_port "${old[@]}"
    fi
}

# Annule une migration : $SSH_PORT reprend l'ancienne valeur (c'est elle que
# step_save_state persistera), et UFW / fail2ban — déjà passés sur le nouveau
# port aux étapes 4 et 6 — sont réalignés.
ssh_revert_port() {
    local new="$SSH_PORT"
    SSH_PORT="$1"
    ufw delete limit "${new}/tcp" >/dev/null 2>&1 || true
    ufw limit "${SSH_PORT}/tcp" comment 'SSH (rate-limited)' >/dev/null 2>&1 || true
    if [[ -f /etc/fail2ban/jail.local ]]; then
        sed -i "/^\[sshd\]/,/^\[/ s/^port .*/port     = ${SSH_PORT}/" /etc/fail2ban/jail.local
        systemctl restart fail2ban >/dev/null 2>&1 || true
    fi
    log_warn "Migration annulée : SSH reste sur le port ${SSH_PORT}."
}

step_ssh_phase1() {
    log_step "Configuration SSH — phase 1 (transition)"
    if ssh_already_hardened; then
        log_info "SSH déjà verrouillé (détecté), phase 1 ignorée pour ne pas rouvrir l'accès root par mot de passe."
        return
    fi
    # Pendant la transition, sshd écoute sur le port actuel ET sur $SSH_PORT :
    # la session en cours et un éventuel retour arrière restent possibles
    # tant que le nouveau port n'a pas été validé (phase 2).
    local -a ports=()
    mapfile -t ports < <(ssh_current_ports)
    [[ "${#ports[@]}" -eq 0 ]] && ports=(22)
    ports+=("$SSH_PORT")
    backup_file "$SSHD_HARDENING_FILE"
    cat > "$SSHD_HARDENING_FILE" <<EOF
# Phase 1 : root et mot de passe encore autorisés, pour ne pas se retrouver
# bloqué hors du serveur pendant la transition vers le compte admin.
$(ssh_port_directives "${ports[@]}")
PubkeyAuthentication yes
PermitRootLogin yes
PasswordAuthentication yes
AllowUsers ${ADMIN_USER} root
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
PermitEmptyPasswords no
EOF
    test_sshd_config
    ssh_restart "${ports[@]}" || log_warn "Vérifier l'écoute de sshd avant de poursuivre : ss -ltnp | grep sshd"
    log_ok "SSH en mode transition (root + mot de passe encore actifs, fail2ban déjà actif)."
}

###############################################################################
# 6. UFW — RÈGLES DE BASE
###############################################################################
step_ufw_base() {
    log_step "Configuration du pare-feu (UFW)"
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    ufw limit "${SSH_PORT}/tcp" comment 'SSH (rate-limited)' >/dev/null
    # Changement de port en cours : tant que sshd écoute encore sur un autre
    # port (nouveau port pas encore validé), celui-ci reste ouvert — activer
    # UFW sans lui fermerait la seule porte dont on sait qu'elle fonctionne.
    # Fermé par la phase 2 (ou la migration) après validation.
    local ssh_p
    while IFS= read -r ssh_p; do
        [[ -z "$ssh_p" || "$ssh_p" == "$SSH_PORT" ]] && continue
        ufw limit "${ssh_p}/tcp" comment 'SSH (transition de port)' >/dev/null
        log_info "Port SSH ${ssh_p} laissé ouvert le temps de valider le port ${SSH_PORT}."
    done < <(ssh_current_ports)
    ufw allow 80/tcp comment 'HTTP' >/dev/null
    ufw allow 443/tcp comment 'HTTPS' >/dev/null
    ufw allow 443/udp comment 'HTTP/3 QUIC' >/dev/null

    # Nettoyage des éventuelles anciennes règles sur le port 3000 (évite les
    # doublons/conflits si le script est relancé avec une restriction IP différente).
    local attempts=0 rule_num
    while ufw status numbered | grep -q '3000/tcp' && (( attempts < 10 )); do
        rule_num=$(ufw status numbered | grep '3000/tcp' | head -n1 | grep -oP '^\[\s*\K[0-9]+' || true)
        [[ -z "$rule_num" ]] && break
        yes | ufw delete "$rule_num" >/dev/null 2>&1 || true
        attempts=$((attempts+1))
    done

    # Le port 3000 (UI Dokploy) n'a de sens que pour un rôle manager, et
    # seulement tant qu'il n'a pas été fermé manuellement (`vps-helper
    # close-dokploy`, qui persiste ce choix dans $STATE_FILE) : sans ces deux
    # gardes, un rôle remote se retrouvait avec 3000/tcp ouvert pour rien, et
    # une relance en mode mise à jour rouvrait un port fermé exprès.
    if [[ "$SERVER_ROLE" != "1" ]]; then
        log_info "Rôle 'remote server' : port 3000 (Dokploy) non ouvert, non applicable."
    elif [[ "$DOKPLOY_PORT_CLOSED" == "1" ]]; then
        log_info "Port 3000 laissé fermé (fermé précédemment via « vps-helper close-dokploy »)."
    elif [[ -n "$DOKPLOY_RESTRICT_IP" ]]; then
        ufw allow from "$DOKPLOY_RESTRICT_IP" to any port 3000 proto tcp comment 'Dokploy UI (IP restreinte)' >/dev/null
    else
        ufw allow 3000/tcp comment 'Dokploy UI - a fermer manuellement apres config domaine' >/dev/null
        log_warn "Port 3000 ouvert à tous. Fermeture requise une fois le domaine et le TLS configurés dans Dokploy (sudo vps-helper close-dokploy)."
    fi

    ufw --force enable >/dev/null
    log_ok "Pare-feu actif."
    ufw status verbose | tee -a "$LOG_FILE"
}

###############################################################################
# 7. DURCISSEMENT SSH — PHASE 2 (verrouillage final, après confirmation)
###############################################################################
step_ssh_phase2() {
    log_step "Configuration SSH — phase 2 (verrouillage)"
    if ssh_already_hardened; then
        # Seul changement possible sur un serveur verrouillé : le port.
        ssh_port_migration
        return
    fi

    local ip_hint
    ip_hint=$(curl -s -4 --max-time 3 ifconfig.me || echo '<IP_DU_SERVEUR>')

    echo ""
    log_warn "=== ÉTAPE DE VALIDATION OBLIGATOIRE ==="
    echo "Ouvrir un NOUVEAU terminal (sans fermer celui-ci) et tester la connexion :"
    echo ""
    echo -e "    ${C_GREEN}$(ssh_cmd_hint "$ip_hint")${C_RESET}"
    echo ""
    if [[ "$SSH_PORT" != "22" ]]; then
        log_warn "Pare-feu externe (Hetzner Cloud Firewall…) : ${SSH_PORT}/tcp doit y être autorisé, sinon ce test échouera."
    fi
    if [[ -f "$PASSWORD_FILE" ]]; then
        log_secret "Mot de passe sudo pour ${ADMIN_USER} : $(cat "$PASSWORD_FILE")"
        log_warn "À conserver si nécessaire (utile pour 'sudo -i')."
    fi
    echo "Vérifier également l'accès root via : sudo -i"
    echo ""

    confirm "La connexion avec ${ADMIN_USER} fonctionne et sudo est validé, verrouiller SSH maintenant ?" "n" \
        || error "Verrouillage SSH annulé. Relancer le script une fois prêt : les étapes déjà réalisées seront ignorées."

    backup_file "$SSHD_HARDENING_FILE"
    write_sshd_final_config "$SSH_PORT"
    test_sshd_config
    ssh_restart "$SSH_PORT" || log_warn "Vérifier l'écoute de sshd AVANT de fermer cette session : ss -ltnp | grep sshd"
    # Port de transition (si le port a changé) : validé à l'instant, on ferme.
    ssh_close_old_ports
    log_ok "SSH verrouillé : root et mot de passe désactivés, algorithmes modernes appliqués."
}

###############################################################################
# 8. VERROUILLAGE DU COMPTE ROOT (défense en profondeur)
###############################################################################
step_lock_root() {
    log_step "Verrouillage du compte root (local)"
    if passwd -S root 2>/dev/null | awk '{print $2}' | grep -q '^L'; then
        log_info "Compte root déjà verrouillé, rien à faire."
        return
    fi
    passwd -l root >/dev/null 2>&1 || true
    log_ok "Compte root verrouillé (plus de connexion par mot de passe, y compris en local — PermitRootLogin no protège déjà le SSH)."
}

###############################################################################
# 9. UNATTENDED-UPGRADES
###############################################################################
step_unattended_upgrades() {
    log_step "Mises à jour de sécurité automatiques"
    backup_file /etc/apt/apt.conf.d/50unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

    backup_file /etc/apt/apt.conf.d/20auto-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    systemctl enable unattended-upgrades >/dev/null 2>&1
    systemctl restart unattended-upgrades
    log_ok "Mises à jour de sécurité automatiques configurées (sans reboot auto)."
}

###############################################################################
# 10. DURCISSEMENT SYSCTL (RÉSEAU + MÉMOIRE)
###############################################################################
step_sysctl_hardening() {
    log_step "Durcissement sysctl (réseau + mémoire)"
    backup_file /etc/sysctl.d/99-hardening.conf
    backup_file /etc/sysctl.d/99-memory.conf
    backup_file /etc/sysctl.d/99-network-perf.conf
    cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# Anti spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Pas de source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Pas d'ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Protection SYN flood
net.ipv4.tcp_syncookies = 1

# RFC 1337 : un RST reçu en TIME-WAIT ne tue plus prématurément la socket
# (« TIME-WAIT assassination »). Mesuré à 0 en production : seule clé de
# durcissement réseau réellement manquante — kptr_restrict, dmesg_restrict,
# ptrace_scope, unprivileged_bpf_disabled et fs.protected_* sont déjà durcis
# par défaut sur Ubuntu 24.04, inutile de les reposer.
net.ipv4.tcp_rfc1337 = 1

# Ignore les broadcasts ICMP (anti smurf)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Log des paquets "martian"
net.ipv4.conf.all.log_martians = 1

# Équivalents IPv6 (Hetzner et la plupart des VPS fournissent de l'IPv6).
# NB : on ne touche PAS à accept_ra — le désactiver casserait la route par
# défaut IPv6 sur les VPS configurés en SLAAC/RA.
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# IMPORTANT : requis par le réseau Docker, ne pas désactiver
net.ipv4.ip_forward = 1
EOF

    # Mémoire — volontairement PAS dans 99-swap.conf : cette étape-là retourne
    # tôt quand un swap est déjà actif (partition fournie par le provider), et
    # le réglage serait alors silencieusement absent. Ici il s'applique toujours,
    # et pour les deux rôles : un remote server héberge aussi des conteneurs.
    cat > /etc/sysctl.d/99-memory.conf <<'EOF'
# Redis (celui de Dokploy, et tout conteneur Redis avec persistance) fait un
# fork() pour ecrire ses sauvegardes en arriere-plan. Sans overcommit, ce fork
# peut echouer sous pression memoire : la sauvegarde est perdue en silence.
# Redis emet un WARNING a chaque demarrage tant que ce n'est pas pose.
vm.overcommit_memory = 1

# Hote Docker : on evite de sortir vers le swap des pages froides encore
# utiles (a-coups de latence au reveil d'un conteneur inactif). Le noyau
# recupere du cache plutot que de swapper ; vfs_cache_pressure tempere ca en
# gardant plus longtemps les metadonnees de fichiers.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

    # Performances reseau. Volontairement limite a ces cles : somaxconn,
    # fs.file-max, nf_conntrack_max et tcp_tw_reuse ont ete mesures sur des
    # serveurs reels (jusqu'a 46 conteneurs) et sont deja bons par defaut sur
    # Ubuntu 24.04 — les reposer n'apporterait rien et donnerait l'illusion
    # d'un reglage utile.
    cat > /etc/sysctl.d/99-network-perf.conf <<'EOF'
# BBR + fq : controle de congestion nettement meilleur que cubic sur des
# liaisons longue distance (visiteurs lointains, sauvegardes hors site).
# fq est l'ordonnanceur attendu par BBR ; les deux vont ensemble.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# File d'attente des connexions a demi ouvertes : la valeur par defaut est
# vite atteinte sur un hote qui publie plusieurs dizaines de services.
net.ipv4.tcp_max_syn_backlog = 4096

# Sockets en FIN-WAIT-2 liberees plus vite (60 s par defaut) : un reverse
# proxy ouvre et ferme beaucoup de connexions courtes.
net.ipv4.tcp_fin_timeout = 15

# Tampons UDP maximum pour HTTP/3 (QUIC, active dans Traefik) : quic-go
# demande ~7,5 Mo, le plafond par defaut est 212992 octets. MARGE PREVENTIVE,
# PAS UN CORRECTIF MESURE : aucun avertissement quic-go n'a ete observe dans
# les logs Traefik, et la valeur n'est pas lisible depuis le conteneur. Aucun
# gain de performance n'a ete demontre sur ce serveur.
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
EOF

    # Migration : ces deux clés vivaient dans 99-swap.conf, écrit par step_swap.
    # Sur un serveur déjà provisionné, le laisser donnerait deux sources de
    # vérité pour les mêmes réglages. Valeurs identiques, donc suppression sans
    # risque — sauvegardée comme le reste.
    if [[ -f /etc/sysctl.d/99-swap.conf ]]; then
        backup_file /etc/sysctl.d/99-swap.conf
        rm -f /etc/sysctl.d/99-swap.conf
        log_info "Ancien /etc/sysctl.d/99-swap.conf retiré (réglages repris dans 99-memory.conf)."
    fi

    sysctl_align_ufw
    sysctl_apply
    if sysctl_verify; then
        log_ok "Durcissement sysctl appliqué et vérifié (réseau IPv4/IPv6 + mémoire + performances réseau)."
    else
        log_warn "Durcissement sysctl écrit, mais pas entièrement effectif (divergences ci-dessus)."
    fi
}

# Fichiers sysctl posés par init-vps — liste reprise à l'identique dans
# cmd_check (vps-helper).
SYSCTL_INIT_VPS_FILES=(/etc/sysctl.d/99-hardening.conf /etc/sysctl.d/99-memory.conf /etc/sysctl.d/99-network-perf.conf)

# « clé<TAB>valeur » pour chaque réglage de nos fichiers. Clés en notation
# pointée, espaces de la valeur normalisés (comparables à `sysctl -n`).
sysctl_expected_pairs() {
    awk '/^[[:space:]]*[#;]/ || !/=/ { next }
        { k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
          gsub(/[[:space:]]/, "", k); gsub(/\//, ".", k)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/[[:space:]]+/, " ", v)
          print k "\t" v }' "${SYSCTL_INIT_VPS_FILES[@]}" 2>/dev/null || true
}

# UFW réapplique /etc/ufw/sysctl.conf à chaque enable/reload — donc au boot,
# APRÈS systemd-sysctl. Ce fichier pose notamment log_martians=0 : mesuré en
# production, 99-hardening.conf disait 1 et le runtime 0. Pour les seules clés
# que nous gérons, ses valeurs sont alignées sur les nôtres ; le reste du
# fichier est laissé intact.
sysctl_align_ufw() {
    local ufw_sysctl=/etc/ufw/sysctl.conf pairs tmp changed
    [[ -f "$ufw_sysctl" ]] || return 0
    pairs="$(sysctl_expected_pairs)"
    [[ -n "$pairs" ]] || return 0
    tmp="$(mktemp)"
    changed="$(mktemp)"
    awk -v changed="$changed" 'NR == FNR { split($0, kv, "\t"); want[kv[1]] = kv[2]; next }
        /^[[:space:]]*[#;]/ || !/=/ { print; next }
        { k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
          gsub(/[[:space:]]/, "", k); nk = k; gsub(/\//, ".", nk)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if ((nk in want) && want[nk] != v) {
              print "# init-vps : aligné sur /etc/sysctl.d (valeur précédente : " v ")"
              print k "=" want[nk]
              print nk > changed
              next
          }
          print }' <(printf '%s\n' "$pairs") "$ufw_sysctl" > "$tmp"
    if [[ -s "$changed" ]]; then
        backup_file "$ufw_sysctl"
        # cat > et non mv : conserve propriétaire et droits du fichier d'origine.
        cat "$tmp" > "$ufw_sysctl"
        log_info "/etc/ufw/sysctl.conf aligné (UFW y réappliquait d'autres valeurs après le boot) : $(paste -sd' ' "$changed")"
    fi
    rm -f "$tmp" "$changed"
}

# Plus de `sysctl --system >/dev/null 2>&1` : une clé refusée passait
# inaperçue. Chaque ligne d'erreur est journalisée.
sysctl_apply() {
    local out rc=0 line
    out="$(sysctl --system 2>&1)" || rc=$?
    while IFS= read -r line; do
        case "$line" in
            *"cannot stat /proc/sys/net/ipv6/"*)
                log_info "sysctl : ${line} (IPv6 désactivé ?)" ;;
            sysctl:*)
                log_warn "sysctl : ${line}" ;;
        esac
    done <<< "$out"
    if (( rc != 0 )); then
        log_warn "sysctl --system a terminé en erreur (code ${rc}) : au moins un réglage n'est pas appliqué."
    fi
    return 0
}

# Fichiers (autres que les nôtres) qui définissent $1 avec une autre valeur
# que $2 — la cause la plus probable d'une divergence.
sysctl_conflicting_sources() {
    local key="$1" want="$2" f v re
    re="^[[:space:]]*${key//./[./]}[[:space:]]*="
    for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf \
             /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /etc/ufw/sysctl.conf; do
        [[ -f "$f" ]] || continue
        case " ${SYSCTL_INIT_VPS_FILES[*]} " in *" ${f} "*) continue ;; esac
        v="$(grep -E "$re" "$f" 2>/dev/null | tail -n1 | sed -E "s/${re}//; s/^[[:space:]]+//; s/[[:space:]]+$//" || true)"
        [[ -n "$v" && "$v" != "$want" ]] && printf '%s (=%s) ' "$f" "$v"
    done
    return 0
}

# Écrire un fichier ne prouve pas qu'il a pris : relit chaque clé au runtime.
# Retourne 1 s'il existe au moins une divergence.
sysctl_verify() {
    local key want have sources bad=0 checked=0
    while IFS=$'\t' read -r key want; do
        [[ -z "$key" ]] && continue
        if ! have="$(sysctl -n "$key" 2>/dev/null)"; then
            case "$key" in
                net.ipv6.*) log_info "sysctl ${key} : absente du noyau (IPv6 désactivé ?)." ;;
                *) log_warn "sysctl ${key} : clé inconnue du noyau."; bad=$((bad+1)) ;;
            esac
            continue
        fi
        checked=$((checked+1))
        have="$(tr -s '[:space:]' ' ' <<< "$have" | sed 's/^ //; s/ $//')"
        if [[ "$have" != "$want" ]]; then
            log_warn "sysctl ${key} : attendu « ${want} », effectif « ${have} »."
            sources="$(sysctl_conflicting_sources "$key" "$want")"
            [[ -n "$sources" ]] && log_warn "    défini autrement dans : ${sources}"
            bad=$((bad+1))
        fi
    done < <(sysctl_expected_pairs)
    [[ "$bad" -eq 0 ]] && log_info "sysctl : ${checked} réglage(s) relu(s) au runtime, tous conformes."
    [[ "$bad" -eq 0 ]]
}

###############################################################################
# 11. SWAP
###############################################################################
step_swap() {
    log_step "Création du swap"
    if [[ "$SWAP_SIZE_GB" -eq 0 ]]; then
        if swapon --show --noheadings 2>/dev/null | grep -q .; then
            log_info "Swap déjà actif ($(free -h | awk '/^Swap:/ {print $2}')), création ignorée."
        else
            log_info "Aucun swap demandé (0 Go), création ignorée."
        fi
        return
    fi
    # Détecte tout swap déjà actif (swapfile OU partition fournie par le provider)
    # pour ne pas empiler un swapfile inutile par-dessus.
    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        log_warn "Un swap est déjà actif sur ce serveur, étape ignorée."
        return
    fi

    # fallocate peut réussir mais produire un fichier que swapon refuse (extents
    # non contigus sur certains FS type ZFS/btrfs). On repasse alors sur dd.
    rm -f /swapfile
    if ! fallocate -l "${SWAP_SIZE_GB}G" /swapfile; then
        dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB*1024)) status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    if ! swapon /swapfile 2>/dev/null; then
        log_warn "swapon a échoué (probable fichier non contigu), recréation via dd..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB*1024)) status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile || error "Impossible d'activer le swap sur /swapfile."
    fi
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

    log_ok "Swap de ${SWAP_SIZE_GB} Go créé."
}

###############################################################################
# 12. FUSEAU HORAIRE, NTP, LIMITES DE LOGS
###############################################################################
step_system_misc() {
    log_step "Fuseau horaire, NTP et limites de logs"
    timedatectl set-timezone "$TIMEZONE"
    timedatectl set-ntp true

    mkdir -p /etc/systemd/journald.conf.d
    backup_file /etc/systemd/journald.conf.d/99-size-limit.conf
    cat > /etc/systemd/journald.conf.d/99-size-limit.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
    systemctl restart systemd-journald
    log_ok "Fuseau horaire réglé sur ${TIMEZONE}, logs journald limités à 200 Mo."
}

###############################################################################
# 13. MOTD PERSONNALISÉ
###############################################################################
step_motd() {
    log_step "Personnalisation du MOTD (message de connexion SSH)"

    # Désactive les scripts MOTD par défaut d'Ubuntu (news, pubs ESM, alertes
    # de fin de support...) pour ne garder qu'un affichage propre et uniforme.
    if [[ -d /etc/update-motd.d ]]; then
        chmod -x /etc/update-motd.d/* 2>/dev/null || true
    fi
    systemctl disable --now motd-news.timer >/dev/null 2>&1 || true
    : > /etc/motd 2>/dev/null || true

    # /etc/legal (notice « free software / NO WARRANTY ») est affiché à chaque
    # connexion par pam_motd.so — on le vide pour un login épuré.
    if [[ -s /etc/legal ]]; then
        backup_file /etc/legal
        : > /etc/legal 2>/dev/null || true
    fi

    # Le hint « To run a command as administrator… » vient de /etc/bash.bashrc et
    # s'affiche tant que ~/.sudo_as_admin_successful est absent. On crée le
    # marqueur pour le compte admin (mécanisme prévu par Ubuntu, non invasif).
    if [[ -n "${ADMIN_USER:-}" ]] && id "$ADMIN_USER" &>/dev/null; then
        local admin_home
        admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
        if [[ -n "$admin_home" && -d "$admin_home" ]]; then
            touch "${admin_home}/.sudo_as_admin_successful"
            chown "${ADMIN_USER}:${ADMIN_USER}" "${admin_home}/.sudo_as_admin_successful" 2>/dev/null || true
        fi
    fi

    mkdir -p /etc/update-motd.d
    backup_file /etc/update-motd.d/00-studiokyne
    cat > /etc/update-motd.d/00-studiokyne <<'MOTDEOF'
#!/usr/bin/env bash
# MOTD — généré par init-vps.sh, design uniforme à chaque connexion.

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_CYAN='\033[0;36m'; C_YELLOW='\033[0;33m'; C_GREEN='\033[0;32m'

HOSTNAME_VAL="$(hostname)"
OS_PRETTY="$( . /etc/os-release; echo "$PRETTY_NAME" )"
KERNEL="$(uname -r)"
UPTIME_VAL="$(uptime -p 2>/dev/null | sed 's/^up //')"
LOAD_VAL="$(cut -d' ' -f1-3 /proc/loadavg)"
MEM_VAL="$(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
DISK_VAL="$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
IP_LOCAL="$(hostname -I 2>/dev/null | awk '{print $1}')"

if command -v docker &>/dev/null; then
    DOCKER_COUNT="$(docker ps -q 2>/dev/null | wc -l)"
    SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)"
    DOCKER_LINE="${DOCKER_COUNT} conteneur(s) actif(s) — swarm: ${SWARM_STATE:-inactive}"
else
    DOCKER_LINE="non installé"
fi

if [[ -f /var/run/reboot-required ]]; then
    REBOOT_PKGS="$(tr '\n' ',' < /var/run/reboot-required.pkgs 2>/dev/null | sed 's/,$//' | sed 's/,/, /g')"
    if [[ -n "$REBOOT_PKGS" ]]; then
        REBOOT_LINE="${C_YELLOW}requis${C_RESET} (${REBOOT_PKGS})"
    else
        REBOOT_LINE="${C_YELLOW}requis${C_RESET}"
    fi
    # Redémarrage automatique planifié (fichier root-only : lisible par
    # pam_motd, pas par `vps-helper status` lancé sans sudo).
    if [[ -r /var/lib/init-vps/reboot-planned ]]; then
        REBOOT_AT="$(date -d "@$(cut -d' ' -f1 /var/lib/init-vps/reboot-planned)" '+%d/%m %H:%M' 2>/dev/null)"
        if [[ -n "$REBOOT_AT" ]]; then
            REBOOT_LINE="${REBOOT_LINE} — automatique le ${REBOOT_AT} (vps-helper reboot-skip)"
        fi
    fi
else
    REBOOT_LINE="${C_GREEN}non requis${C_RESET}"
fi

printf '\n'
printf "${C_CYAN}  ┌──────────────────────────────────────────────────┐${C_RESET}\n"
printf "${C_CYAN}  │${C_RESET} ${C_BOLD}%-51s${C_RESET}${C_CYAN}│${C_RESET}\n" "${HOSTNAME_VAL}"
printf "${C_CYAN}  └──────────────────────────────────────────────────┘${C_RESET}\n"
printf "  ${C_DIM}%-10s${C_RESET} %s\n" "Système"   "${OS_PRETTY} (${KERNEL})"
printf "  ${C_DIM}%-10s${C_RESET} %s\n" "Uptime"    "${UPTIME_VAL}"
printf "  ${C_DIM}%-10s${C_RESET} %s\n" "Charge"    "${LOAD_VAL}"
printf "  ${C_DIM}%-10s${C_RESET} %s\n" "Mémoire"   "${MEM_VAL}"
printf "  ${C_DIM}%-10s${C_RESET} %s\n" "Disque /"  "${DISK_VAL}"
printf "  ${C_DIM}%-10s${C_RESET} %s\n" "IP locale" "${IP_LOCAL}"
printf "  ${C_DIM}%-10s${C_RESET} %s\n" "Docker"    "${DOCKER_LINE}"
printf "  ${C_DIM}%-10s${C_RESET} %b\n" "Reboot"    "${REBOOT_LINE}"
printf "\n  ${C_DIM}Administration du serveur :${C_RESET} ${C_BOLD}vps-helper${C_RESET} (commandes disponibles : vps-helper help)\n"
printf '\n'
MOTDEOF
    chmod +x /etc/update-motd.d/00-studiokyne

    # Sur Ubuntu 24.04, pam_motd.so est configuré avec noupdate par défaut :
    # les scripts update-motd.d ne sont exécutés qu'au boot, pas à chaque login.
    # On supprime ce flag pour que le MOTD reflète l'état courant à chaque connexion.
    if grep -q 'pam_motd.so noupdate' /etc/pam.d/sshd 2>/dev/null; then
        backup_file /etc/pam.d/sshd
        sed -i 's/pam_motd.so noupdate$/pam_motd.so/' /etc/pam.d/sshd
    fi
    run-parts /etc/update-motd.d/ > /run/motd.dynamic 2>/dev/null || true

    log_ok "MOTD personnalisé installé."
}

###############################################################################
# 14. COMMANDE D'AIDE — vps-helper
###############################################################################
step_vps_helper() {
    log_step "Installation de la commande d'aide (vps-helper)"
    backup_file /usr/local/bin/vps-helper
    cat > /usr/local/bin/vps-helper <<'HELPEREOF'
#!/usr/bin/env bash
# vps-helper — commandes d'administration pour ce serveur.
# Généré par init-vps.sh. Documentation : vps-helper help

set -uo pipefail

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'
INIT_VPS_VERSION="0.0.0-dev"
DEFAULT_ADMIN_USER=""

info() { echo -e "${C_DIM}[i]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[x]${C_RESET} $*" >&2; }

# chk_fail mémorise aussi chaque message : `check --notify` les envoie tels quels.
CHK_FAIL_MSGS=()
CHK_WARN_N=0
chk_pass() { printf '%b %s\n' "${C_GREEN}[PASS]${C_RESET}" "$1"; }
chk_fail() { printf '%b %s\n' "${C_RED}[FAIL]${C_RESET}" "$1"; CHK_FAIL_MSGS+=("$1"); }
chk_warn() { printf '%b %s\n' "${C_YELLOW}[WARN]${C_RESET}" "$1"; CHK_WARN_N=$((CHK_WARN_N+1)); }
chk_info() { printf '%b %s\n' "${C_CYAN}[INFO]${C_RESET}" "$1"; }
chk_sect() { printf '\n%b%s%b\n' "${C_DIM}── " "$1" " ────────────────────────────────────────${C_RESET}"; }

IV_LIB=/var/lib/init-vps
INIT_VPS_STATE=/etc/init-vps/config.env
NOTIFY_ENV=/etc/init-vps/notify.env

NEED_ROOT_CMDS="whitelist unban close-dokploy restart update check traefik-tuning ssh-keys docker-firewall notify-test notify-set reboot-auto reboot-skip reboot-status"
CMD="${1:-help}"

# Élévation automatique des privilèges via sudo, si nécessaire.
if [[ " $NEED_ROOT_CMDS " == *" $CMD "* ]] && [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

print_help() {
    local help_text
    help_text=$(cat <<EOF

${C_BOLD}vps-helper${C_RESET} — commandes d'administration de ce serveur

  ${C_CYAN}vps-helper status${C_RESET}              État du serveur (identique au message de connexion)
  ${C_CYAN}vps-helper whitelist <IP>${C_RESET}      Ajouter une IP de confiance (jamais bannie par fail2ban)
  ${C_CYAN}vps-helper unban <IP>${C_RESET}          Débannir une IP bannie par fail2ban
  ${C_CYAN}vps-helper close-dokploy${C_RESET}       Fermer l'accès direct au port 3000 (Dokploy)
  ${C_CYAN}vps-helper ssh-keys list [user]${C_RESET}    Lister les clés SSH d'un utilisateur (défaut : compte admin)
  ${C_CYAN}vps-helper ssh-keys add [user]${C_RESET}     Ajouter une clé SSH (invite à la coller)
  ${C_CYAN}vps-helper ssh-keys remove [user]${C_RESET}  Supprimer une clé SSH (choix dans une liste numérotée)
  ${C_CYAN}vps-helper restart <service>${C_RESET}   Redémarrer un service : ssh, fail2ban, docker
  ${C_CYAN}vps-helper logs <conteneur>${C_RESET}    Afficher les logs d'un conteneur Docker (Ctrl+C pour quitter)
  ${C_CYAN}vps-helper update${C_RESET}              Mettre à jour le système (sécurité incluse)
  ${C_CYAN}vps-helper check${C_RESET}               Vérifier l'état du durcissement (lecture seule)
  ${C_CYAN}vps-helper traefik-tuning${C_RESET}      Activer HTTP/3 + compression Traefik (idempotent)
  ${C_CYAN}vps-helper docker-firewall <action>${C_RESET}
                                 Filtrage des ports publiés par Docker (DOCKER-USER)
                                 status : état et ports exposés · apply : (re)poser
                                 les règles · clear : les retirer
  ${C_CYAN}vps-helper notify-set${C_RESET}          Poser ou changer l'URL du webhook (puis envoi de test)
  ${C_CYAN}vps-helper notify-test [fail]${C_RESET}  Notification de test (fail : alerte qui notifie)
  ${C_CYAN}vps-helper reboot-status${C_RESET}       Redémarrage requis / planifié
  ${C_CYAN}vps-helper reboot-skip${C_RESET}         Reporter de 24 h le redémarrage automatique planifié
  ${C_CYAN}vps-helper version${C_RESET}             Afficher la version de init-vps.sh utilisée
  ${C_CYAN}vps-helper help${C_RESET}                Afficher cette aide
EOF
)
    printf '%b\n' "$help_text"
}

cmd_status() {
    if [[ -x /etc/update-motd.d/00-studiokyne ]]; then
        /etc/update-motd.d/00-studiokyne
    else
        err "Script de statut introuvable (/etc/update-motd.d/00-studiokyne)."
        exit 1
    fi
}

cmd_whitelist() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && { err "Usage : vps-helper whitelist <IP>"; exit 1; }
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        err "« ${ip} » ne ressemble pas à une IP ou un CIDR valide (ex: 1.2.3.4 ou 1.2.3.0/24)."
        exit 1
    fi

    local jail_file="/etc/fail2ban/jail.local"
    [[ -f "$jail_file" ]] || { err "Fichier ${jail_file} introuvable."; exit 1; }

    if grep "^ignoreip" "$jail_file" 2>/dev/null | grep -qw "$ip"; then
        info "${ip} est déjà dans la liste blanche fail2ban."
        return
    fi

    cp -a "$jail_file" "${jail_file}.bak-$(date +%Y%m%d%H%M%S)"
    if grep -q "^ignoreip" "$jail_file"; then
        sed -i "/^ignoreip/ s/\$/ ${ip}/" "$jail_file"
    else
        sed -i "/^\[DEFAULT\]/a ignoreip = 127.0.0.1/8 ::1 ${ip}" "$jail_file"
    fi
    systemctl restart fail2ban
    ok "${ip} ajoutée à la liste blanche fail2ban (ne sera jamais bannie)."
}

cmd_unban() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && { err "Usage : vps-helper unban <IP>"; exit 1; }
    if fail2ban-client unban "$ip" >/dev/null 2>&1; then
        ok "${ip} débannie."
    else
        warn "${ip} n'était bannie dans aucune jail (ou fail2ban indisponible)."
    fi
}

# --- Gestion interactive des clés SSH -------------------------------------
# NOTE : dupliquée à l'identique depuis validate_ssh_pubkey() dans le script
# parent (collect_ssh_keys) — heredoc en guillemets simples, impossible de
# partager la fonction. Garder les deux regex synchronisées en cas de modif.
validate_ssh_pubkey() {
    local key="$1"
    [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]
}

# Résout et valide l'utilisateur cible. Écrit le nom sur stdout (à capturer
# via $(...)) et retourne un code d'erreur si invalide — ne jamais faire
# `exit` ici : sous $(...) ça ne quitterait qu'un sous-shell, pas le script.
resolve_ssh_user() {
    local u="${1:-$DEFAULT_ADMIN_USER}"
    if [[ -z "$u" ]]; then
        err "Aucun utilisateur cible. Usage : vps-helper ssh-keys <list|add|remove> [utilisateur]"
        return 1
    fi
    if ! id "$u" &>/dev/null; then
        err "Utilisateur « ${u} » introuvable."
        return 1
    fi
    printf '%s' "$u"
}

ssh_keys_file() {
    local home_dir
    home_dir="$(getent passwd "$1" | cut -d: -f6)"
    printf '%s/.ssh/authorized_keys' "$home_dir"
}

# Lit authorized_keys dans le tableau global SSH_KEYS_LINES (ignore lignes
# vides/commentaires). Utilisé par list et remove pour partager le même
# affichage numéroté.
load_ssh_keys_lines() {
    SSH_KEYS_LINES=()
    local line
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        SSH_KEYS_LINES+=("$line")
    done < "$1"
}

print_ssh_keys_lines() {
    local i keytype comment
    for i in "${!SSH_KEYS_LINES[@]}"; do
        keytype=$(awk '{print $1}' <<< "${SSH_KEYS_LINES[$i]}")
        comment=$(awk '{for (j=3;j<=NF;j++) printf "%s ", $j}' <<< "${SSH_KEYS_LINES[$i]}")
        printf '  %b%2d)%b %-20s %s\n' "${C_CYAN}" "$((i+1))" "${C_RESET}" "$keytype" "${comment:-<sans commentaire>}"
    done
}

cmd_ssh_keys_list() {
    local user; user="$(resolve_ssh_user "${1:-}")" || exit 1
    local file; file="$(ssh_keys_file "$user")"
    if [[ ! -s "$file" ]]; then
        info "Aucune clé SSH pour ${user}."
        return
    fi
    local SSH_KEYS_LINES=()
    load_ssh_keys_lines "$file"
    info "Clés SSH de ${user} (${file}) :"
    print_ssh_keys_lines
}

cmd_ssh_keys_add() {
    local user; user="$(resolve_ssh_user "${1:-}")" || exit 1
    local file; file="$(ssh_keys_file "$user")"
    local key
    read -rp "Coller la clé publique SSH à ajouter pour ${user} : " key
    if ! validate_ssh_pubkey "$key"; then
        err "Format de clé SSH invalide (attendu : ssh-ed25519/ssh-rsa/ecdsa-... suivi de la clé)."
        exit 1
    fi
    install -d -m 700 -o "$user" -g "$user" "$(dirname "$file")"
    touch "$file"
    if grep -qxF "$key" "$file" 2>/dev/null; then
        info "Cette clé est déjà présente pour ${user}."
        return
    fi
    cp -a "$file" "${file}.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    echo "$key" >> "$file"
    chmod 600 "$file"
    chown "${user}:${user}" "$file" 2>/dev/null || true
    ok "Clé SSH ajoutée pour ${user}."
}

cmd_ssh_keys_remove() {
    local user; user="$(resolve_ssh_user "${1:-}")" || exit 1
    local file; file="$(ssh_keys_file "$user")"
    if [[ ! -s "$file" ]]; then
        info "Aucune clé SSH pour ${user}."
        return
    fi
    local SSH_KEYS_LINES=()
    load_ssh_keys_lines "$file"
    if [[ "${#SSH_KEYS_LINES[@]}" -le 1 ]]; then
        err "Une seule clé restante pour ${user} — suppression refusée (risque de perte d'accès SSH)."
        exit 1
    fi
    info "Clés SSH de ${user} :"
    print_ssh_keys_lines
    local choice
    read -rp "Numéro de la clé à supprimer (Ctrl+C pour annuler) : " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SSH_KEYS_LINES[@]} )); then
        err "Choix invalide."
        exit 1
    fi
    local removed="${SSH_KEYS_LINES[$((choice-1))]}"
    local confirm_input
    read -rp "$(printf '%b' "${C_YELLOW}?${C_RESET} Supprimer la clé #${choice} (${removed:0:50}...) ? [o/N] : ")" confirm_input
    if ! [[ "${confirm_input,,}" =~ ^(o|oui|y|yes)$ ]]; then
        info "Annulé."
        return
    fi
    cp -a "$file" "${file}.bak-$(date +%Y%m%d%H%M%S)"
    unset 'SSH_KEYS_LINES[choice-1]'
    printf '%s\n' "${SSH_KEYS_LINES[@]}" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    chmod 600 "$file"
    chown "${user}:${user}" "$file" 2>/dev/null || true
    ok "Clé SSH supprimée pour ${user}."
}

cmd_ssh_keys() {
    local sub="${1:-list}"
    [[ $# -gt 0 ]] && shift
    case "$sub" in
        list)             cmd_ssh_keys_list "$@" ;;
        add)              cmd_ssh_keys_add "$@" ;;
        remove|rm|delete) cmd_ssh_keys_remove "$@" ;;
        *)
            err "Sous-commande inconnue : « ${sub} ». Utiliser : list, add, remove."
            exit 1
            ;;
    esac
}

cmd_close_dokploy() {
    local attempts=0 rule_num found=0
    while ufw status numbered | grep -q '3000/tcp' && (( attempts < 10 )); do
        rule_num=$(ufw status numbered | grep '3000/tcp' | head -n1 | grep -oP '^\[\s*\K[0-9]+' || true)
        [[ -z "$rule_num" ]] && break
        yes | ufw delete "$rule_num" >/dev/null 2>&1 || true
        found=1
        attempts=$((attempts+1))
    done
    if [[ "$found" -eq 1 ]]; then
        ok "Port 3000 fermé. Désactivation de l'accès direct via IP:port recommandée dans les réglages Dokploy."
    else
        info "Aucune règle ouverte sur le port 3000, rien à fermer."
    fi

    # Persiste le choix dans l'état sauvegardé par init-vps.sh, pour qu'une
    # relance ultérieure en mode mise à jour (`init-vps.sh --update`) ne
    # rouvre pas ce port automatiquement via step_ufw_base.
    local state_file="/etc/init-vps/config.env"
    if [[ -f "$state_file" ]]; then
        if grep -q '^DOKPLOY_PORT_CLOSED=' "$state_file" 2>/dev/null; then
            sed -i 's/^DOKPLOY_PORT_CLOSED=.*/DOKPLOY_PORT_CLOSED="1"/' "$state_file"
        else
            echo 'DOKPLOY_PORT_CLOSED="1"' >> "$state_file"
        fi
    fi
}

cmd_restart() {
    local svc="${1:-}"
    case "$svc" in
        ssh)
            if sshd -t 2>/tmp/vps-helper-sshd-test.err; then
                systemctl restart ssh
                ok "SSH redémarré."
            else
                err "Configuration SSH invalide, redémarrage annulé :"
                cat /tmp/vps-helper-sshd-test.err >&2
                exit 1
            fi
            ;;
        fail2ban)
            systemctl restart fail2ban
            ok "fail2ban redémarré."
            ;;
        docker)
            systemctl restart docker
            ok "Docker redémarré (les services Swarm se relancent automatiquement)."
            ;;
        *)
            err "Service inconnu : « ${svc} ». Services gérés : ssh, fail2ban, docker."
            exit 1
            ;;
    esac
}

cmd_logs() {
    local container="${1:-}"
    if [[ -z "$container" ]]; then
        info "Conteneurs actifs :"
        docker ps --format '  {{.Names}}'
        echo ""
        info "Usage : vps-helper logs <nom-conteneur>"
        return
    fi
    docker logs --tail 100 -f "$container"
}

cmd_update() {
    info "Mise à jour du système (apt update + dist-upgrade)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get dist-upgrade -y
    apt-get autoremove --purge -y
    ok "Système à jour."
    if [[ -f /var/run/reboot-required ]]; then
        warn "Un redémarrage est nécessaire pour appliquer certaines mises à jour."
    fi
}

cmd_version() {
    echo "${INIT_VPS_VERSION}"
}

cmd_traefik_tuning() {
    local tconf="/etc/dokploy/traefik/traefik.yml"
    local mdir="/etc/dokploy/traefik/dynamic"
    local mconf="${mdir}/middlewares.yml"

    if [[ ! -f "$tconf" ]]; then
        err "traefik.yml introuvable (${tconf}) — Dokploy est-il installé ?"
        exit 1
    fi

    # yq (mikefarah) : indispensable pour un patch YAML sûr et idempotent.
    if ! command -v yq >/dev/null 2>&1; then
        info "Installation de yq (mikefarah)..."
        local arch; arch=$(dpkg --print-architecture)
        if ! curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
                -o /usr/local/bin/yq; then
            err "Téléchargement de yq impossible — optimisation Traefik annulée."
            exit 1
        fi
        chmod +x /usr/local/bin/yq
    fi

    local changed=0 stamp
    stamp=$(date +%Y%m%d%H%M%S)

    # --- 1. middlewares.yml : définir le middleware « compression » s'il manque ---
    mkdir -p "$mdir"
    [[ -f "$mconf" ]] || printf 'http:\n  middlewares: {}\n' > "$mconf"
    if [[ "$(yq '.http.middlewares.compression // "null"' "$mconf")" == "null" ]]; then
        cp -a "$mconf" "${mconf}.bak-${stamp}"
        local frag; frag=$(mktemp)
        cat > "$frag" <<'FRAGEOF'
http:
  middlewares:
    compression:
      compress:
        encodings:
          - zstd
          - br
          - gzip
        defaultEncoding: br
        minResponseBodyBytes: 1024
        excludedContentTypes:
          - image/jpeg
          - image/png
          - image/gif
          - image/webp
          - image/avif
          - video/mp4
          - video/webm
          - application/pdf
          - application/zip
          - application/gzip
          - application/x-gzip
FRAGEOF
        # Merge profond : ajoute uniquement « compression », préserve les autres
        # middlewares (redirect-to-https, addprefix générés par Dokploy, etc.).
        yq -i eval-all '. as $item ireduce ({}; . * $item)' "$mconf" "$frag"
        rm -f "$frag"
        changed=1
        ok "Middleware « compression » ajouté à dynamic/middlewares.yml."
    else
        info "Middleware « compression » déjà présent."
    fi

    # Sauvegarde de traefik.yml avant toute modification (une seule fois),
    # uniquement si un patch est réellement nécessaire.
    local tconf_needs_patch=0
    [[ "$(yq '.entryPoints.websecure.http3.advertisedPort // "null"' "$tconf")" == "null" ]] && tconf_needs_patch=1
    if ! yq '.entryPoints.websecure.http.middlewares // [] | .[]' "$tconf" | grep -qx 'compression@file'; then
        tconf_needs_patch=1
    fi
    [[ "$tconf_needs_patch" -eq 1 ]] && cp -a "$tconf" "${tconf}.bak-${stamp}"

    # --- 2. traefik.yml : HTTP/3 sur websecure ---
    if [[ "$(yq '.entryPoints.websecure.http3.advertisedPort // "null"' "$tconf")" == "null" ]]; then
        yq -i '.entryPoints.websecure.http3.advertisedPort = 443' "$tconf"
        changed=1
        ok "HTTP/3 activé sur l'entrypoint websecure."
    else
        info "HTTP/3 déjà activé."
    fi

    # --- 3. traefik.yml : attacher compression@file en middleware global websecure ---
    if ! yq '.entryPoints.websecure.http.middlewares // [] | .[]' "$tconf" \
            | grep -qx 'compression@file'; then
        yq -i '.entryPoints.websecure.http.middlewares += ["compression@file"]' "$tconf"
        changed=1
        ok "Middleware compression@file attaché à websecure."
    else
        info "Middleware compression@file déjà attaché."
    fi

    # HTTP/3 = QUIC sur UDP/443 : s'assurer que le pare-feu laisse passer l'UDP
    # (utile si cette commande est lancée sur un serveur provisionné avant l'ajout
    # de la règle UDP/443 dans step_ufw_base). ufw allow est idempotent.
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        if ! ufw status 2>/dev/null | grep -qE '443/udp'; then
            ufw allow 443/udp comment 'HTTP/3 QUIC' >/dev/null 2>&1 \
                && ok "Port UDP/443 ouvert dans UFW (QUIC/HTTP-3)." \
                || warn "Impossible d'ouvrir UDP/443 dans UFW — à vérifier manuellement."
        else
            info "Port UDP/443 déjà ouvert dans UFW."
        fi
    fi

    # --- 4. rechargement ---
    # Selon la version de Dokploy, Traefik tourne soit comme service Swarm
    # (docker service), soit comme conteneur classique (docker run). On gère
    # les deux : service d'abord, puis conteneur nommé dokploy-traefik.
    if [[ "$changed" -eq 1 ]]; then
        if docker service ls --format '{{.Name}}' 2>/dev/null | grep -q '^dokploy-traefik$'; then
            if docker service update --force dokploy-traefik >/dev/null 2>&1; then
                ok "Service Traefik rechargé (config statique appliquée)."
            else
                warn "Rechargement Traefik échoué — relance : docker service update --force dokploy-traefik"
            fi
        elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^dokploy-traefik$'; then
            if docker restart dokploy-traefik >/dev/null 2>&1; then
                ok "Conteneur Traefik redémarré (config statique appliquée)."
            else
                warn "Redémarrage Traefik échoué — relance : docker restart dokploy-traefik"
            fi
        else
            warn "Traefik (dokploy-traefik) introuvable — redémarre-le pour appliquer HTTP/3."
        fi
    else
        info "Configuration Traefik déjà optimale, aucun changement."
    fi
}

# --- Ports publiés par Docker / chaîne DOCKER-USER --------------------------
# UFW ne filtre PAS les ports publiés par Docker : leur trafic traverse
# FORWARD (DOCKER-USER, DOCKER-FORWARD) sans passer par les chaînes ufw-*.
# Ces trois fonctions servent à la fois à `check` et à `docker-firewall`.
DOCKER_USER_APPLY=/usr/local/lib/docker-user/apply.sh

# Un « port/proto » par ligne, dédoublonné. `done < <(...)` et non un pipe :
# la boucle doit tourner dans le shell courant.
# Deux sources, car aucune n'est complète : un service Swarm publié en mode
# ingress n'apparaît PAS dans `docker ps` (son conteneur de tâche ne montre
# que ses ports internes) — seul `docker service ls` le liste, sous la forme
# « *:3000->3000/tcp ». À l'inverse, un conteneur hors Swarm n'existe que
# dans `docker ps`.
docker_port_sources() {
    docker ps --format '{{.Ports}}' 2>/dev/null || true
    docker service ls --format '{{.Ports}}' 2>/dev/null || true
}

docker_published_public_ports() {
    command -v docker >/dev/null 2>&1 || return 0
    local line chunk hostport proto
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local -a chunks=()
        IFS=',' read -ra chunks <<< "$line"
        for chunk in "${chunks[@]}"; do
            chunk="${chunk// /}"
            [[ "$chunk" == *'->'* ]] || continue
            # 0.0.0.0:/[::]: pour un conteneur, *: pour un service Swarm.
            [[ "$chunk" == 0.0.0.0:* || "$chunk" == '[::]:'* || "$chunk" == '*:'* ]] || continue
            hostport="${chunk%%->*}"
            hostport="${hostport##*:}"
            proto="${chunk##*/}"
            echo "${hostport}/${proto}"
        done
    done < <(docker_port_sources) | sort -u
}

docker_user_rules() {
    iptables -S DOCKER-USER 2>/dev/null | grep -v '^-N ' || true
}

docker_user_chain_is_empty() {
    [ -z "$(docker_user_rules)" ]
}

docker_user_rule_count() {
    docker_user_rules | grep -c '^-A' || true
}

cmd_docker_firewall() {
    local action="${1:-status}"

    if ! command -v iptables >/dev/null 2>&1; then
        err "iptables introuvable — impossible de piloter la chaîne DOCKER-USER."
        exit 1
    fi

    case "$action" in
        status)
            printf '\n%b\n' "${C_BOLD}Filtrage des ports publiés par Docker${C_RESET}"
            if docker_user_chain_is_empty; then
                warn "Chaîne DOCKER-USER vide : les ports publiés par les conteneurs ne sont filtrés par rien sur ce serveur (UFW ne les voit pas)."
                info "La protection ne dépend alors que d'un éventuel pare-feu externe (Hetzner Cloud Firewall & assimilés), invisible depuis ici."
                info "Poser les règles : vps-helper docker-firewall apply"
            else
                ok "Chaîne DOCKER-USER remplie ($(docker_user_rule_count) règle(s))."
                docker_user_rules | sed 's/^/    /'
            fi
            if command -v ip6tables >/dev/null 2>&1 && ip6tables -S DOCKER-USER >/dev/null 2>&1; then
                local n6
                n6=$(ip6tables -S DOCKER-USER 2>/dev/null | grep -c '^-A' || true)
                if [ "${n6:-0}" -gt 0 ]; then
                    ok "Chaîne DOCKER-USER IPv6 remplie (${n6} règle(s))."
                else
                    info "Chaîne DOCKER-USER IPv6 vide : sans effet tant que l'IPv6 reste désactivé dans Docker."
                fi
            fi
            if systemctl is-enabled docker-user-rules.service >/dev/null 2>&1; then
                ok "Unit docker-user-rules.service activée (règles réappliquées au démarrage)."
            else
                warn "Unit docker-user-rules.service non activée : les règles ne survivront pas à un redémarrage."
            fi
            printf '\n%b\n' "${C_BOLD}Ports publiés (conteneurs et services Swarm)${C_RESET}"
            # L'état de la chaîne est connu ici : annoncer « bloqué SI les
            # règles sont posées » alors qu'on vient de les lister serait une
            # hypothèse là où on a la réponse.
            local published found=0 filtered=1
            docker_user_chain_is_empty && filtered=0
            while IFS= read -r published; do
                [ -z "$published" ] && continue
                found=1
                case "$published" in
                    80/tcp|443/tcp|443/udp)
                        info "  ${published} (autorisé)" ;;
                    *)
                        if [ "$filtered" -eq 1 ]; then
                            warn "  ${published} (bloqué depuis Internet par DOCKER-USER)"
                        else
                            warn "  ${published} (exposé à Internet : aucune règle DOCKER-USER)"
                        fi
                        ;;
                esac
            done < <(docker_published_public_ports)
            [ "$found" -eq 0 ] && info "  aucun"
            ;;
        apply)
            if [ ! -x "$DOCKER_USER_APPLY" ]; then
                err "${DOCKER_USER_APPLY} introuvable — relancer init-vps.sh (mode mise à jour) pour l'installer."
                exit 1
            fi
            if ! docker_user_chain_is_empty && ! docker_user_rules | grep -q -- '--comment init-vps'; then
                err "La chaîne DOCKER-USER contient des règles qui ne viennent pas d'init-vps — application refusée pour ne pas les écraser."
                docker_user_rules | sed 's/^/    /'
                exit 1
            fi
            "$DOCKER_USER_APPLY"
            systemctl enable docker-user-rules.service >/dev/null 2>&1 || true
            ok "Règles DOCKER-USER appliquées (80, 443/tcp, 443/udp et réseaux privés autorisés ; le reste bloqué)."
            ;;
        clear)
            # Filet de sécurité : si les règles cassent un service, on revient
            # à l'état d'origine (chaîne vide) sans avoir à relancer le script.
            iptables -F DOCKER-USER 2>/dev/null || true
            ip6tables -F DOCKER-USER 2>/dev/null || true
            systemctl disable docker-user-rules.service >/dev/null 2>&1 || true
            warn "Chaîne DOCKER-USER vidée et unit désactivée : les ports publiés par Docker ne sont plus filtrés localement."
            info "Les reposer : vps-helper docker-firewall apply"
            ;;
        *)
            err "Action inconnue : « ${action} » (attendu : status, apply ou clear)."
            exit 1
            ;;
    esac
}

# --- Contrôles de `check` -----------------------------------------------------
# Les fonctions check_* sont appelées depuis cmd_check et incrémentent ses
# compteurs locaux `pass` / `fail` par portée dynamique.

# Âge minimal en deçà duquel « max 0 » dans memory.events ne prouve rien : les
# compteurs repartent à zéro à chaque recréation du conteneur. 24 h couvrent
# un cycle complet (tâches nocturnes, pic de trafic de la journée).
MEM_EVENTS_MIN_AGE=86400

# Limite atteinte (`max > 0`) : bénigne ou non ? Critère = efficacité du reclaim,
# lue dans memory.stat : pgsteal ÷ max = pages réellement libérées par dépassement.
#   - Sain   : cron WordPress à 512M — max 13 945, oom_kill 0, file 57 Mio,
#              pgscan 944 650 / pgsteal 944 613 (~68 pages par dépassement),
#              pgmajfault 48. Le noyau libère du cache de pages froid.
#   - Malade : même cron forcé à 128M, `wp cron event run` tué (exit 137) —
#              max 48, oom_kill 1, file 0, pgscan 0 / pgsteal 0 : plus rien à
#              libérer, l'OOM suit.
# Rejetés : le coût PSI (full total ÷ max) ne distingue rien — 86 µs par reclaim
# pour le sain, 19 µs (893 ÷ 48) et 108 µs (36 692 ÷ 340, oom_kill 2) pour les
# malades. workingset_refault_file vaut 374 007 sur le cas sain (wp relit ses
# PHP à chaque cycle).
MEM_RECLAIM_MIN_PAGES=16
# Garde-fou thrashing : code mappé évincé puis relu depuis le disque sans OOM —
# pgsteal non nul mais pgmajfault élevé. FAIL si pgmajfault > ce plancher ET
# pgmajfault × 10 > max. Seuil PROVISOIRE : ce cas n'a jamais été mesuré avec
# ces compteurs (méthode de test dans CLAUDE.md).
MEM_MAJFAULT_FLOOR=100

human_bytes() { numfmt --to=iec --suffix=o "$1" 2>/dev/null || echo "${1} o"; }

human_age() {
    local s="${1:-0}"
    if [ "$s" -ge 86400 ]; then echo "$((s/86400)) j"
    elif [ "$s" -ge 3600 ]; then echo "$((s/3600)) h"
    else echo "$((s/60)) min"
    fi
}

# Journal noyau depuis le boot. journalctl d'abord : le tampon circulaire de
# dmesg est court et tourne vite sur un hôte chargé — un OOM vieux de trois
# semaines peut en être sorti, et « aucun OOM » deviendrait un faux PASS.
kernel_log() {
    if command -v journalctl >/dev/null 2>&1 \
            && journalctl -k -b -q --no-pager -n 1 2>/dev/null | grep -q .; then
        journalctl -k -b -q --no-pager 2>/dev/null
    else
        dmesg 2>/dev/null
    fi
}

# Répertoire cgroup v2 d'un conteneur : driver systemd (Ubuntu 24.04), puis
# cgroupfs, puis ce que rapporte le noyau pour son process principal.
container_cgroup_dir() {
    local id="$1" pid="$2" rel
    for rel in "system.slice/docker-${id}.scope" "docker/${id}"; do
        [ -f "/sys/fs/cgroup/${rel}/memory.events" ] && { echo "/sys/fs/cgroup/${rel}"; return 0; }
    done
    rel="$(awk -F: '$1 == "0" {print $3}' "/proc/${pid}/cgroup" 2>/dev/null)"
    [ -n "$rel" ] && [ -f "/sys/fs/cgroup${rel}/memory.events" ] && { echo "/sys/fs/cgroup${rel}"; return 0; }
    return 1
}

# Deux mécanismes distincts, deux sources :
#   - OOM kill    → journal noyau (« Memory cgroup out of memory »)
#   - throttling  → INVISIBLE dans le journal : le noyau récupère des pages au
#     lieu de tuer, le service survit mais thrashe. Seul le compteur `max` de
#     memory.events le trahit. Mesuré en production : 35 652 fois en quelques
#     semaines, conteneur « Up (healthy »), aucun log applicatif.
#   - efficacité du reclaim → memory.stat (pgsteal, pgmajfault) : `max` compte
#     aussi les reclaims de cache de pages bénins. Le PSI ne les distingue pas
#     (86 µs par reclaim sain, 19 à 108 µs sur des cas malades mesurés).
check_container_memory() {
    chk_sect "Mémoire des conteneurs"
    if ! command -v docker >/dev/null 2>&1; then
        chk_info "Docker absent"
        return
    fi

    # 1) OOM kills — ID résolu en nom : un hash de 64 caractères ne se diagnostique pas.
    local oom_lines cg_n global_n names="" count id name
    if ! kernel_log | head -n 1 | grep -q .; then
        chk_info "Journal noyau illisible : OOM kills non vérifiables"
    else
        oom_lines="$(kernel_log | grep -E 'Out of memory|oom-kill:' || true)"
        cg_n=$(grep -c 'Memory cgroup out of memory' <<< "$oom_lines" || true)
        global_n=$(grep 'Out of memory: Kill' <<< "$oom_lines" | grep -vc 'Memory cgroup' || true)
        while read -r count id; do
            [ -z "$id" ] && continue
            name="$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null)"
            names="${names}${names:+, }${name:+${name#/}}${name:-${id} (conteneur disparu)} (${count}×)"
        done < <(grep 'oom-kill:' <<< "$oom_lines" \
            | grep -oP 'task_memcg=/(system\.slice/docker-|docker/)\K[0-9a-f]{12}' | sort | uniq -c)
        if [ "${cg_n:-0}" -eq 0 ]; then
            chk_pass "Aucun process tué pour dépassement de limite mémoire (cgroup) depuis le boot"; pass=$((pass+1))
        else
            chk_fail "${cg_n} process tué(s) par OOM cgroup depuis le boot${names:+ : ${names}}"; fail=$((fail+1))
        fi
        if [ "${global_n:-0}" -gt 0 ]; then
            chk_fail "${global_n} OOM global(aux) depuis le boot : la mémoire de l'hôte entier a été épuisée"; fail=$((fail+1))
        fi
    fi

    # 2) Throttling et pic mémoire — pour chaque conteneur en cours d'exécution.
    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        chk_info "cgroup v1 : memory.events indisponible, throttling mémoire non vérifiable"
        return
    fi
    local -a ids=() young=()
    mapfile -t ids < <(docker ps -q --no-trunc 2>/dev/null)
    if [ "${#ids[@]}" -eq 0 ]; then
        chk_info "Aucun conteneur en cours d'exécution"
        return
    fi
    local now full pid started dir max_ev oom_ev limit peak age start_s ratio
    local steal majf benign
    local -a cheap=()
    local ok_n=0 unlimited_n=0 unreadable_n=0
    now=$(date +%s)
    while read -r name full pid started; do
        name="${name#/}"
        dir="$(container_cgroup_dir "$full" "$pid")" || { unreadable_n=$((unreadable_n+1)); continue; }
        max_ev=$(awk '$1 == "max" {print $2}' "${dir}/memory.events")
        oom_ev=$(awk '$1 == "oom_kill" {print $2}' "${dir}/memory.events")
        limit=$(cat "${dir}/memory.max" 2>/dev/null)
        peak=$(cat "${dir}/memory.peak" 2>/dev/null)
        # Date illisible → âge 0 → « non concluant » : l'erreur penche du côté prudent.
        start_s=$(date -d "$started" +%s 2>/dev/null || echo "$now")
        age=$((now - start_s))

        # Un OOM kill est concluant quel que soit l'âge du conteneur.
        if [ "${oom_ev:-0}" -gt 0 ]; then
            chk_fail "${name} : ${oom_ev} OOM kill(s) en $(human_age "$age") (limite $(human_bytes "$limit"), atteinte ${max_ev:-0} fois)"
            fail=$((fail+1))
            continue
        fi
        # Limite atteinte : bénin si le noyau n'a libéré que du cache froid, grave
        # s'il n'y a plus rien à libérer ou si le code est relu depuis le disque.
        # pgsteal / pgmajfault en correspondance exacte (pas pgsteal_direct, etc.).
        benign=0
        if [ "${max_ev:-0}" -gt 0 ]; then
            steal=$(awk '$1 == "pgsteal" {print $2}' "${dir}/memory.stat" 2>/dev/null)
            majf=$(awk '$1 == "pgmajfault" {print $2}' "${dir}/memory.stat" 2>/dev/null)
            if ! [[ "$steal" =~ ^[0-9]+$ ]] || ! [[ "$majf" =~ ^[0-9]+$ ]]; then
                chk_fail "${name} : limite atteinte ${max_ev} fois en $(human_age "$age"), efficacité du reclaim illisible — limite $(human_bytes "$limit")"
                fail=$((fail+1))
                continue
            fi
            if [ "$steal" -lt $((max_ev * MEM_RECLAIM_MIN_PAGES)) ]; then
                chk_fail "${name} : limite atteinte ${max_ev} fois sans mémoire récupérable ($((steal / max_ev)) pages libérées par dépassement) en $(human_age "$age") — limite $(human_bytes "$limit"), risque d'OOM"
                fail=$((fail+1))
                continue
            fi
            if [ "$majf" -gt "$MEM_MAJFAULT_FLOOR" ] && [ $((majf * 10)) -gt "$max_ev" ]; then
                chk_fail "${name} : thrashing — limite atteinte ${max_ev} fois, ${majf} relectures disque de code en $(human_age "$age") — limite $(human_bytes "$limit")"
                fail=$((fail+1))
                continue
            fi
            cheap+=("${name} (${max_ev} dépassements, $((steal / max_ev)) pages de cache libérées chacun)")
            benign=1
        fi
        if [ -z "$limit" ] || [ "$limit" = "max" ]; then
            unlimited_n=$((unlimited_n+1))
            continue
        fi
        # Alerte précoce : le pic approche la limite avant que `max` ne bouge.
        # Sans objet si la limite est déjà atteinte avec un reclaim de cache
        # efficace (peak = limite).
        if [ "$benign" -eq 0 ] && [ -n "$peak" ] && [ "$limit" -gt 0 ]; then
            ratio=$((peak * 100 / limit))
            if [ "$ratio" -ge 90 ]; then
                chk_warn "${name} : pic mémoire à ${ratio} % de la limite ($(human_bytes "$peak") / $(human_bytes "$limit")) — throttling imminent"
                continue
            fi
        fi
        # `max 0` sur un conteneur récent ne prouve rien : pas de faux « tout va bien ».
        if [ "$age" -lt "$MEM_EVENTS_MIN_AGE" ]; then
            young+=("${name} (démarré il y a $(human_age "$age"))")
            continue
        fi
        ok_n=$((ok_n+1))
    done < <(docker inspect --format '{{.Name}} {{.Id}} {{.State.Pid}} {{.State.StartedAt}}' "${ids[@]}" 2>/dev/null)

    if [ "$ok_n" -gt 0 ]; then
        chk_pass "${ok_n} conteneur(s) limité(s) sans throttling ni OOM depuis au moins $(human_age "$MEM_EVENTS_MIN_AGE")"; pass=$((pass+1))
    fi
    if [ "${#cheap[@]}" -gt 0 ]; then
        chk_info "Limite atteinte, cache de pages libéré sans effet sur les process :"
        printf '      %s\n' "${cheap[@]}"
    fi
    if [ "${#young[@]}" -gt 0 ]; then
        chk_info "Non concluant pour ${#young[@]} conteneur(s) récent(s) — compteurs remis à zéro à chaque recréation :"
        printf '      %s\n' "${young[@]}"
    fi
    [ "$unlimited_n" -gt 0 ] && chk_info "${unlimited_n} conteneur(s) sans limite mémoire (pas de throttling propre, OOM global possible)"
    [ "$unreadable_n" -gt 0 ] && chk_info "${unreadable_n} conteneur(s) dont le cgroup est introuvable (non vérifiés)"
    return 0
}

# Valeur numérique d'une ligne de `fail2ban-client status <jail>`.
f2b_stat() {
    fail2ban-client status "$1" 2>/dev/null | grep -F "$2" | grep -oE '[0-9]+$' | head -n 1
}

# Une jail active n'est pas une jail qui voit quelque chose : recidive héritait
# de « backend = systemd » et cherchait les bans dans le journal, alors que
# fail2ban les écrit dans son fichier. Mesuré : « Total failed: 0 » pendant des
# semaines face à 18 bans sur sshd — et `check` affichait PASS.
check_fail2ban_recidive() {
    if ! fail2ban-client status 2>/dev/null | grep 'Jail list:' | grep -q 'recidive'; then
        chk_fail "Jail recidive non activée"; fail=$((fail+1))
        return
    fi
    local status rec_failed started new_bans=0
    status="$(fail2ban-client status recidive 2>/dev/null)"
    if ! grep -q 'File list:.*fail2ban\.log' <<< "$status"; then
        chk_fail "Jail recidive aveugle : elle ne lit pas /var/log/fail2ban.log (backend journal hérité) — corriger : relancer init-vps.sh --update"; fail=$((fail+1))
        return
    fi
    rec_failed="$(grep -F 'Total failed' <<< "$status" | grep -oE '[0-9]+$')"
    # Bans posés par les autres jails depuis le démarrage de fail2ban : si
    # recidive lit bien le fichier, chacun a dû incrémenter son compteur.
    started="$(systemctl show fail2ban -p ActiveEnterTimestamp --value 2>/dev/null)"
    started="$(date -d "$started" '+%F %T' 2>/dev/null)"
    if [ -n "$started" ] && [ -r /var/log/fail2ban.log ]; then
        new_bans=$(awk -v since="$started" 'substr($0, 1, 19) >= since && / Ban / && !/Restore Ban/ && !/\[recidive\]/' \
            /var/log/fail2ban.log | wc -l)
    fi
    if [ "${rec_failed:-0}" -gt 0 ]; then
        chk_pass "Jail recidive active et alimentée (${rec_failed} ban(s) d'autres jails pris en compte)"; pass=$((pass+1))
    elif [ "$new_bans" -gt 0 ]; then
        chk_fail "Jail recidive aveugle : ${new_bans} ban(s) écrit(s) dans fail2ban.log depuis le démarrage, 0 vu"; fail=$((fail+1))
    else
        chk_info "Jail recidive active, lecture non vérifiable : aucun ban depuis le démarrage de fail2ban (${started:-date inconnue})"
    fi
}

# Où fail2ban pose-t-il ses bans ? Avec banaction nftables (défaut Ubuntu
# 24.04), dans sa propre table « inet f2b-table », INVISIBLE depuis
# `iptables -S` — même en iptables-nft. Ne chercher que côté iptables annonçait
# « aucune règle f2b » alors que les bans fonctionnaient.
check_fail2ban_bans() {
    local banned=0 j n jails backend="absent" ipt=0 nft=0
    jails="$(fail2ban-client status 2>/dev/null | grep 'Jail list:' | sed 's/.*Jail list:[[:space:]]*//; s/,/ /g')"
    for j in $jails; do
        n="$(f2b_stat "$j" 'Currently banned')"
        banned=$((banned + ${n:-0}))
    done
    if command -v iptables >/dev/null 2>&1; then
        if iptables --version 2>/dev/null | grep -q nf_tables; then backend="iptables-nft"; else backend="iptables-legacy"; fi
        ipt=$({ iptables -S 2>/dev/null; ip6tables -S 2>/dev/null; } | grep -c 'f2b' || true)
    fi
    if command -v nft >/dev/null 2>&1; then
        nft=$(nft list ruleset 2>/dev/null | grep -c 'f2b' || true)
    fi
    if ! command -v iptables >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
        chk_info "Ni iptables ni nft disponibles : application des bans non vérifiable"
    elif [ "${ipt:-0}" -gt 0 ] || [ "${nft:-0}" -gt 0 ]; then
        chk_pass "Bans fail2ban appliqués au pare-feu : ${banned} IP bannie(s) (lignes f2b — nftables : ${nft:-0}, iptables : ${ipt:-0} ; backend ${backend})"; pass=$((pass+1))
    elif [ "$banned" -gt 0 ]; then
        chk_fail "${banned} IP bannie(s) par fail2ban, mais aucune règle f2b dans nftables ni iptables : bans non appliqués"; fail=$((fail+1))
    else
        chk_info "Aucune IP bannie en ce moment, aucune règle f2b attendue"
    fi
}

# Liste dupliquée depuis SYSCTL_INIT_VPS_FILES (script parent) : heredoc en
# guillemets simples, rien ne peut être partagé. Garder les deux synchronisées.
SYSCTL_INIT_VPS_FILES="/etc/sysctl.d/99-hardening.conf /etc/sysctl.d/99-memory.conf /etc/sysctl.d/99-network-perf.conf"

# Écrire un fichier sysctl ne prouve pas qu'il a pris. Mesuré : log_martians = 1
# dans 99-hardening.conf, 0 au runtime — /etc/ufw/sysctl.conf, réappliqué par
# UFW après le boot, le remettait à zéro.
check_sysctl() {
    chk_sect "sysctl (réglages posés par init-vps)"
    local key want have f v re sources ok_n=0 files=""
    for f in $SYSCTL_INIT_VPS_FILES; do
        [ -f "$f" ] && files="${files} ${f}"
    done
    if [ -z "$files" ]; then
        chk_info "Aucun fichier sysctl d'init-vps présent"
        return
    fi
    while IFS=$'\t' read -r key want; do
        [ -z "$key" ] && continue
        if ! have="$(sysctl -n "$key" 2>/dev/null)"; then
            case "$key" in
                net.ipv6.*) chk_info "${key} : absente du noyau (IPv6 désactivé ?)" ;;
                *) chk_fail "${key} : clé inconnue du noyau"; fail=$((fail+1)) ;;
            esac
            continue
        fi
        have="$(tr -s '[:space:]' ' ' <<< "$have" | sed 's/^ //; s/ $//')"
        if [ "$have" = "$want" ]; then
            ok_n=$((ok_n+1))
            continue
        fi
        sources=""
        re="^[[:space:]]*${key//./[./]}[[:space:]]*="
        for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /etc/ufw/sysctl.conf; do
            [ -f "$f" ] || continue
            case " ${SYSCTL_INIT_VPS_FILES} " in *" ${f} "*) continue ;; esac
            v="$(grep -E "$re" "$f" 2>/dev/null | tail -n 1 | sed -E "s/${re}//; s/^[[:space:]]+//; s/[[:space:]]+$//")"
            [ -n "$v" ] && [ "$v" != "$want" ] && sources="${sources} ${f}(=${v})"
        done
        chk_fail "${key} : attendu « ${want} », effectif « ${have} »${sources:+ — défini autrement dans${sources}}"; fail=$((fail+1))
    done < <(awk '/^[[:space:]]*[#;]/ || !/=/ { next }
        { k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
          gsub(/[[:space:]]/, "", k); gsub(/\//, ".", k)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/[[:space:]]+/, " ", v)
          print k "\t" v }' $files)
    [ "$ok_n" -gt 0 ] && { chk_pass "${ok_n} réglage(s) conforme(s) au runtime"; pass=$((pass+1)); }
    return 0
}

# Ce que rien ne signalait : unit en échec, disque plein, reboot en attente
# depuis des semaines, unattended-upgrades en erreur.
check_system() {
    chk_sect "Système"
    local failed use mnt disk_issue=0 now age
    now=$(date +%s)

    failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ')"
    if [ -z "$failed" ]; then
        chk_pass "Aucune unit systemd en échec"; pass=$((pass+1))
    else
        chk_fail "Unit(s) systemd en échec : ${failed}"; fail=$((fail+1))
    fi

    while read -r use mnt; do
        use="${use%\%}"
        if [ "$use" -ge 90 ]; then
            chk_fail "Disque ${mnt} rempli à ${use} %"; fail=$((fail+1)); disk_issue=1
        elif [ "$use" -ge 80 ]; then
            chk_warn "Disque ${mnt} rempli à ${use} %"; disk_issue=1
        fi
    done < <(df -P -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null \
        | awk 'NR > 1 && !seen[$1]++ {print $5, $6}')
    [ "$disk_issue" -eq 0 ] && { chk_pass "Espace disque sous 80 % partout"; pass=$((pass+1)); }

    # Au-delà de 7 jours, c'est un échec, pas une information — redémarrage
    # automatique désactivé, ou reporté trop souvent.
    if [ -f /var/run/reboot-required ]; then
        age=$((now - $(stat -c %Y /var/run/reboot-required 2>/dev/null || echo "$now")))
        local planned=""
        if [ -f "$REBOOT_PLANNED" ]; then
            planned=" — automatique le $(date -d "@$(cut -d' ' -f1 "$REBOOT_PLANNED")" '+%d/%m à %H:%M' 2>/dev/null)"
        fi
        if [ "$age" -ge 604800 ]; then
            chk_fail "Redémarrage requis depuis $(human_age "$age")${planned}"; fail=$((fail+1))
        else
            chk_warn "Redémarrage requis (depuis $(human_age "$age"))${planned}"
        fi
    else
        chk_pass "Aucun redémarrage en attente"; pass=$((pass+1))
    fi

    local uu_log=/var/log/unattended-upgrades/unattended-upgrades.log uu_err
    if systemctl is-failed --quiet apt-daily-upgrade.service 2>/dev/null; then
        chk_fail "Dernière exécution d'unattended-upgrades en échec (journalctl -u apt-daily-upgrade)"; fail=$((fail+1))
    elif [ -r "$uu_log" ]; then
        # Erreurs de la DERNIÈRE exécution seulement, pas de tout l'historique.
        uu_err=$(awk '/Starting unattended upgrades script/ {n = 0} /ERROR/ {n++} END {print n + 0}' "$uu_log")
        if [ "$uu_err" -gt 0 ]; then
            chk_fail "Dernière exécution d'unattended-upgrades : ${uu_err} erreur(s) (${uu_log})"; fail=$((fail+1))
        else
            chk_pass "Dernière exécution d'unattended-upgrades sans erreur"; pass=$((pass+1))
        fi
    fi
}

# Un redémarrage (automatique ou non) ne relance que les conteneurs qui le
# demandent. Les tâches Swarm, elles, sont relancées par Swarm quelle que soit
# la politique de leur conteneur.
check_restart_policies() {
    command -v docker >/dev/null 2>&1 || return 0
    chk_sect "Redémarrage des conteneurs"
    local -a ids=()
    mapfile -t ids < <(docker ps -q 2>/dev/null)
    if [ "${#ids[@]}" -eq 0 ]; then
        chk_info "Aucun conteneur en cours d'exécution"
        return
    fi
    local name policy task list=""
    while read -r name policy task; do
        [ "$task" = "-" ] || continue
        case "$policy" in always|unless-stopped|on-failure) continue ;; esac
        list="${list}${list:+, }${name#/}"
    done < <(docker inspect --format '{{.Name}} {{or .HostConfig.RestartPolicy.Name "no"}} {{with index .Config.Labels "com.docker.swarm.task.id"}}{{.}}{{else}}-{{end}}' "${ids[@]}" 2>/dev/null)
    if [ -n "$list" ]; then
        chk_warn "Sans politique de redémarrage, ne reviendront pas après un reboot : ${list}"
    else
        chk_pass "Tous les conteneurs reviennent seuls après un reboot (Swarm ou politique de redémarrage)"; pass=$((pass+1))
    fi
}

# Anti-bruit, pensé pour un webhook partagé par plusieurs serveurs :
#   - échecs nouveaux ou différents → UN message, qui notifie ;
#   - même liste qu'au dernier envoi → rien, rappel au plus tous les 7 jours.
#     Chiffres retirés avant comparaison : « depuis 8 j » puis « 9 j » n'est
#     pas nouveau ; un nouveau conteneur, une nouvelle unit, un disque, si ;
#   - retour au vert → le dernier message d'alerte est MODIFIÉ (silencieux).
check_notify_failures() {
    command -v vps-notify >/dev/null 2>&1 || return 0
    local state="${IV_LIB}/check-notify.state" body hash now id last_hash="" last_ts=0 last_id=""
    now=$(date +%s)
    [ -f "$state" ] && read -r last_hash last_ts last_id < "$state"

    if [ "${#CHK_FAIL_MSGS[@]}" -eq 0 ]; then
        [ -n "$last_hash" ] || return 0
        if [ -z "$last_id" ] || ! vps-notify --level ok --edit "$last_id" "Audit revenu au vert" \
                "Les échecs signalés ont disparu (constaté le $(date '+%d/%m à %H:%M'))." >/dev/null 2>&1; then
            vps-notify --level ok "Audit revenu au vert" "Plus aucun échec." >/dev/null 2>&1
        fi
        rm -f "$state"
        return 0
    fi

    body="$(printf '• %s\n' "${CHK_FAIL_MSGS[@]}")"
    hash="$(tr -d '0-9' <<< "$body" | sha256sum | cut -d' ' -f1)"
    if [ "$hash" = "$last_hash" ] && [ $((now - ${last_ts:-0})) -lt 604800 ]; then
        return 0
    fi
    if id="$(vps-notify --level fail --print-id "${#CHK_FAIL_MSGS[@]} échec(s) à l'audit" "$body")"; then
        mkdir -p "$IV_LIB"
        echo "$hash $now ${id}" > "$state"
    fi
}

state_get() {
    grep -oP "^${1}=\"\K[^\"]*" "$INIT_VPS_STATE" 2>/dev/null | head -n 1
}

state_set() {
    [ -f "$INIT_VPS_STATE" ] || return 0
    if grep -q "^${1}=" "$INIT_VPS_STATE"; then
        sed -i "s|^${1}=.*|${1}=\"${2}\"|" "$INIT_VPS_STATE"
    else
        echo "${1}=\"${2}\"" >> "$INIT_VPS_STATE"
    fi
}

require_vps_notify() {
    if ! command -v vps-notify >/dev/null 2>&1; then
        err "vps-notify introuvable — relancer init-vps.sh (mode mise à jour)."
        exit 1
    fi
}

cmd_notify_test() {
    local level="${1:-info}"
    case "$level" in
        info|fail) ;;
        *) err "Usage : vps-helper notify-test [fail]"; exit 1 ;;
    esac
    require_vps_notify
    if vps-notify --level "$level" "Test de notification" "Envoyé par vps-helper notify-test."; then
        if [ "$level" = "info" ]; then
            ok "Notification envoyée (niveau info : silencieuse sur Discord). Tester une alerte qui notifie : vps-helper notify-test fail"
        else
            ok "Alerte de test envoyée."
        fi
    else
        err "Échec de l'envoi (webhook non configuré ou injoignable)."
        exit 1
    fi
}

# Un même webhook sert tous les serveurs : le poser ou le changer ici, sans
# relancer init-vps.sh.
cmd_notify_set() {
    require_vps_notify
    local url
    read -rsp "URL du webhook Discord ou Slack (saisie masquée) : " url
    echo ""
    if ! [[ "$url" =~ ^https://[^[:space:]]+$ ]]; then
        err "URL invalide (https://… attendu)."
        exit 1
    fi
    install -d -m 755 /etc/init-vps
    [ -f "$NOTIFY_ENV" ] && cp -a "$NOTIFY_ENV" "${NOTIFY_ENV}.bak-$(date +%Y%m%d%H%M%S)"
    (umask 077; printf 'NOTIFY_WEBHOOK_URL=%q\n' "$url" > "$NOTIFY_ENV")
    state_set NOTIFY_ENABLED 1
    # L'alerte en cours pointait vers un message de l'ancien webhook.
    rm -f "${IV_LIB}/check-notify.state"
    systemctl enable --now vps-check.timer >/dev/null 2>&1 \
        || warn "vps-check.timer introuvable — relancer init-vps.sh --update pour l'audit quotidien."
    ok "Webhook enregistré (${NOTIFY_ENV}, 600)."
    cmd_notify_test
}

# --- Redémarrage automatique ----------------------------------------------------
# Un seul message Discord par redémarrage, modifié au fil de l'eau :
#   1. /run/reboot-required apparaît → vps-reboot-notice.path → `reboot-auto notice` :
#      planifié à la première fenêtre située au moins REBOOT_MIN_NOTICE plus
#      tard, message silencieux.
#   2. Fenêtre nocturne → vps-reboot-auto.timer → `reboot-auto run` : services
#      mémorisés, message modifié « en cours », reboot.
#   3. 5 min après le boot → vps-reboot-report.timer → `reboot-auto report` :
#      message modifié « redémarré » si tout est revenu ; sinon, NOUVEAU message
#      d'alerte — le seul de ce cycle qui notifie.
REBOOT_PLANNED="${IV_LIB}/reboot-planned"          # « époque id_message »
REBOOT_RUNNING="${IV_LIB}/reboot-in-progress"      # « id_message kernel_avant »
REBOOT_SERVICES="${IV_LIB}/reboot-services-before"
# Le temps de voir l'annonce et de reporter.
REBOOT_MIN_NOTICE=43200

auto_reboot_enabled() {
    [ "$(state_get AUTO_REBOOT)" = "1" ]
}

reboot_reason() {
    local pkgs
    pkgs="$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | paste -sd',' | sed 's/,/, /g')"
    echo "${pkgs:-mise à jour système}"
}

fmt_when() {
    date -d "@$1" '+%d/%m à %H:%M'
}

# Première fenêtre au moins REBOOT_MIN_NOTICE après maintenant. Calculée par
# « date du jour + heure » et non par +86400 : juste aux changements d'heure.
next_reboot_window() {
    local t d e now
    t="$(state_get AUTO_REBOOT_TIME)"
    [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || t="04:00"
    now=$(date +%s)
    for d in 0 1 2; do
        e=$(date -d "$(date -d "+${d} day" +%F) ${t}" +%s 2>/dev/null) || continue
        if [ "$e" -ge $((now + REBOOT_MIN_NOTICE)) ]; then
            echo "$e"
            return 0
        fi
    done
    return 1
}

# Services Swarm par nom de service (les conteneurs de tâche changent de nom
# à chaque relance), autres conteneurs par nom.
services_snapshot() {
    docker ps --format '{{if .Label "com.docker.swarm.service.name"}}{{.Label "com.docker.swarm.service.name"}}{{else}}{{.Names}}{{end}}' 2>/dev/null | sort -u
}

reboot_notice() {
    auto_reboot_enabled || return 0
    [ -f /var/run/reboot-required ] || return 0
    [ -f "$REBOOT_PLANNED" ] && return 0
    local when id
    when="$(next_reboot_window)" || return 1
    mkdir -p "$IV_LIB"
    # Écrit avant l'envoi : le redémarrage est planifié même sans webhook.
    echo "$when" > "$REBOOT_PLANNED"
    id="$(vps-notify --level info --print-id "Redémarrage planifié" \
        "$(printf 'Le %s (± 30 min).\nRaison : %s\nReporter de 24 h : `vps-helper reboot-skip`' "$(fmt_when "$when")" "$(reboot_reason)")" 2>/dev/null)"
    echo "$when ${id}" > "$REBOOT_PLANNED"
    info "Redémarrage planifié le $(fmt_when "$when")."
}

# Décale le redémarrage planifié de 24 h. Affiche la nouvelle époque.
reboot_postpone() {
    local reason="$1" when id
    read -r when id < "$REBOOT_PLANNED"
    when=$(date -d "$(date -d "@$when" '+%F %H:%M') +1 day" +%s)
    echo "$when ${id}" > "$REBOOT_PLANNED"
    if [ -n "$id" ]; then
        vps-notify --level info --edit "$id" "Redémarrage reporté" \
            "$(printf 'Nouvelle date : %s (± 30 min).\nMotif : %s\nReporter encore : `vps-helper reboot-skip`' "$(fmt_when "$when")" "$reason")" >/dev/null 2>&1
    fi
    echo "$when"
}

reboot_run() {
    auto_reboot_enabled || return 0
    if [ ! -f /var/run/reboot-required ]; then
        rm -f "$REBOOT_PLANNED"
        return 0
    fi
    # Jamais sans préavis : un redémarrage requis non annoncé est d'abord planifié.
    if [ ! -f "$REBOOT_PLANNED" ]; then
        reboot_notice
        return 0
    fi
    local when id now waited=0
    read -r when id < "$REBOOT_PLANNED"
    now=$(date +%s)
    # Marge d'une heure : le timer tire dans les 30 min qui suivent la fenêtre.
    [ "${when:-0}" -le $((now + 3600)) ] || return 0

    # Ne jamais couper une installation de paquets en cours.
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        if [ "$waited" -ge 1800 ]; then
            reboot_postpone "apt/dpkg occupé pendant 30 min" >/dev/null
            return 0
        fi
        sleep 60
        waited=$((waited+60))
    done

    mkdir -p "$IV_LIB"
    services_snapshot > "$REBOOT_SERVICES"
    echo "${id:--} $(uname -r)" > "$REBOOT_RUNNING"
    rm -f "$REBOOT_PLANNED"
    if [ -n "$id" ]; then
        vps-notify --level info --edit "$id" "Redémarrage en cours" \
            "$(printf 'Lancé le %s.\nRaison : %s' "$(date '+%d/%m à %H:%M')" "$(reboot_reason)")" >/dev/null 2>&1
    fi
    sync
    systemctl reboot
}

reboot_report() {
    [ -f "$REBOOT_RUNNING" ] || return 0
    local id kernel_before missing="" i=0 total n_missing body
    read -r id kernel_before < "$REBOOT_RUNNING"
    [ "$id" = "-" ] && id=""
    # Swarm relance les tâches progressivement : jusqu'à 10 min de patience.
    while [ "$i" -lt 20 ]; do
        missing="$(comm -23 "$REBOOT_SERVICES" <(services_snapshot))"
        [ -z "$missing" ] && break
        sleep 30
        i=$((i+1))
    done
    total=$(grep -c . "$REBOOT_SERVICES" 2>/dev/null || true)
    n_missing=$(printf '%s' "$missing" | grep -c . || true)
    body="$(printf 'Kernel : %s → %s\nServices revenus : %s/%s' "$kernel_before" "$(uname -r)" "$(( ${total:-0} - ${n_missing:-0} ))" "${total:-0}")"
    if [ -f /var/run/reboot-required ]; then
        body="${body}"$'\n'"Un redémarrage est encore requis."
    fi

    if [ -z "$missing" ]; then
        if [ -z "$id" ] || ! vps-notify --level ok --edit "$id" "Redémarré" "$body" >/dev/null 2>&1; then
            vps-notify --level ok "Redémarré" "$body" >/dev/null 2>&1
        fi
    else
        [ -n "$id" ] && vps-notify --level warn --edit "$id" "Redémarré — services manquants" "$body" >/dev/null 2>&1
        vps-notify --level fail "Redémarrage : ${n_missing} service(s) non revenu(s)" \
            "$(printf '%s\n\n%s' "$body" "$(printf '%s\n' "$missing" | sed 's/^/• /')")" >/dev/null 2>&1
    fi
    rm -f "$REBOOT_RUNNING" "$REBOOT_SERVICES"
}

cmd_reboot_auto() {
    case "${1:-}" in
        notice) reboot_notice ;;
        run)    reboot_run ;;
        report) reboot_report ;;
        *) err "Usage interne : vps-helper reboot-auto <notice|run|report> (lancé par les units vps-reboot-*)"; exit 1 ;;
    esac
}

cmd_reboot_skip() {
    if [ ! -f "$REBOOT_PLANNED" ]; then
        info "Aucun redémarrage automatique planifié."
        return
    fi
    local when
    when="$(reboot_postpone "reporté par ${SUDO_USER:-root}")"
    ok "Redémarrage reporté au $(fmt_when "$when") (± 30 min)."
}

cmd_reboot_status() {
    if auto_reboot_enabled; then
        info "Redémarrage automatique : activé (fenêtre $(state_get AUTO_REBOOT_TIME), uniquement si requis)."
    else
        info "Redémarrage automatique : désactivé."
    fi
    if [ -f /var/run/reboot-required ]; then
        warn "Redémarrage requis : $(reboot_reason)"
    else
        ok "Aucun redémarrage requis."
    fi
    if [ -f "$REBOOT_PLANNED" ]; then
        local when
        read -r when _ < "$REBOOT_PLANNED"
        info "Planifié le $(fmt_when "$when") (± 30 min) — reporter : vps-helper reboot-skip"
    fi
}

cmd_check() {
    local pass=0 fail=0 notify=0
    [ "${1:-}" = "--notify" ] && notify=1

    printf '\n%b\n' "${C_BOLD}Audit du durcissement du serveur${C_RESET}"

    chk_sect "SSH"
    if sshd -T 2>/dev/null | grep -q '^permitrootlogin no'; then
        chk_pass "PermitRootLogin no"; pass=$((pass+1))
    else
        chk_fail "PermitRootLogin non désactivé (attendu : no)"; fail=$((fail+1))
    fi
    if sshd -T 2>/dev/null | grep -q '^passwordauthentication no'; then
        chk_pass "PasswordAuthentication no"; pass=$((pass+1))
    else
        chk_fail "PasswordAuthentication non désactivé (attendu : no)"; fail=$((fail+1))
    fi

    chk_sect "UFW"
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        chk_pass "UFW actif"; pass=$((pass+1))
    else
        chk_fail "UFW inactif"; fail=$((fail+1))
    fi
    if ufw status verbose 2>/dev/null | grep -E '^Default:' | grep -q 'deny (incoming)'; then
        chk_pass "Politique par défaut : deny incoming"; pass=$((pass+1))
    else
        chk_fail "Politique par défaut incoming non configurée à deny"; fail=$((fail+1))
    fi

    chk_sect "fail2ban"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        chk_pass "Service fail2ban actif"; pass=$((pass+1))
    else
        chk_fail "Service fail2ban inactif"; fail=$((fail+1))
    fi
    if fail2ban-client status 2>/dev/null | grep 'Jail list:' | grep -q 'sshd'; then
        chk_pass "Jail sshd activée"; pass=$((pass+1))
    else
        chk_fail "Jail sshd non activée"; fail=$((fail+1))
    fi
    check_fail2ban_recidive
    check_fail2ban_bans

    chk_sect "Compte root"
    if passwd -S root 2>/dev/null | awk '{print $2}' | grep -q '^L'; then
        chk_pass "Compte root verrouillé"; pass=$((pass+1))
    else
        chk_fail "Compte root non verrouillé"; fail=$((fail+1))
    fi

    chk_sect "Docker"
    if [[ -f /etc/docker/daemon.json ]] && grep -q '"max-size"' /etc/docker/daemon.json 2>/dev/null; then
        chk_pass "Rotation des logs Docker configurée (max-size présent)"; pass=$((pass+1))
    else
        chk_fail "Rotation des logs Docker non configurée (/etc/docker/daemon.json absent ou sans max-size)"; fail=$((fail+1))
    fi

    chk_sect "Ports publiés par Docker"
    local port_found=0 published
    while IFS= read -r published; do
        [ -z "$published" ] && continue
        case "$published" in 80/tcp|443/tcp|443/udp) continue ;; esac
        chk_fail "Port ${published} publié sur toutes les interfaces (exposé si DOCKER-USER ne le filtre pas)"; fail=$((fail+1))
        port_found=1
    done < <(docker_published_public_ports)
    if [ "$port_found" -eq 0 ]; then
        chk_pass "Aucun port publié sur toutes les interfaces en dehors de 80/443"; pass=$((pass+1))
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        chk_info "DOCKER-USER : iptables absent, état non vérifiable"
    elif docker_user_chain_is_empty; then
        chk_info "DOCKER-USER : vide — UFW ne filtre pas les ports publiés par Docker, la protection dépend d'un pare-feu externe (corriger : vps-helper docker-firewall apply)"
    else
        chk_info "DOCKER-USER : $(docker_user_rule_count) règle(s) — filtrage actif des ports publiés"
    fi
    # IPv6 : Docker désactivé en v6, les ports publiés passent par docker-proxy
    # (chaîne INPUT, donc UFW) — la chaîne v6 vide est inoffensive. Activer
    # « ipv6 » dans daemon.json les ferait passer par FORWARD, sans filtre.
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -S DOCKER-USER >/dev/null 2>&1; then
        local n6 docker_v6=0
        n6=$(ip6tables -S DOCKER-USER 2>/dev/null | grep -c '^-A' || true)
        # shellcheck disable=SC2046  # un ID de réseau par argument, découpage voulu
        if docker network inspect $(docker network ls -q 2>/dev/null) --format '{{.EnableIPv6}}' 2>/dev/null | grep -q true \
                || grep -qE '"ipv6"[[:space:]]*:[[:space:]]*true' /etc/docker/daemon.json 2>/dev/null; then
            docker_v6=1
        fi
        if [ "${n6:-0}" -gt 0 ]; then
            chk_info "DOCKER-USER (IPv6) : ${n6} règle(s)"
        elif [ "$docker_v6" -eq 1 ]; then
            chk_fail "IPv6 activé dans Docker mais DOCKER-USER (IPv6) vide : ports publiés exposés en IPv6 (corriger : vps-helper docker-firewall apply)"; fail=$((fail+1))
        else
            chk_info "DOCKER-USER (IPv6) : vide, sans effet tant que l'IPv6 reste désactivé dans Docker (à revoir s'il est activé)"
        fi
    fi

    check_container_memory
    check_restart_policies

    chk_sect "Traefik (HTTP/3 + compression)"
    local tconf="/etc/dokploy/traefik/traefik.yml"
    if [[ ! -f "$tconf" ]]; then
        chk_info "Traefik/Dokploy non installé"
    elif ! command -v yq >/dev/null 2>&1; then
        chk_info "yq absent — état non vérifiable (« vps-helper traefik-tuning » l'installe)"
    else
        if [[ "$(yq '.entryPoints.websecure.http3.advertisedPort // "null"' "$tconf")" != "null" ]]; then
            chk_pass "HTTP/3 activé sur websecure"; pass=$((pass+1))
        else
            chk_fail "HTTP/3 non activé (corriger : vps-helper traefik-tuning)"; fail=$((fail+1))
        fi
        if yq '.entryPoints.websecure.http.middlewares // [] | .[]' "$tconf" 2>/dev/null \
                | grep -qx 'compression@file'; then
            chk_pass "Middleware compression attaché à websecure"; pass=$((pass+1))
        else
            chk_fail "Compression non attachée (corriger : vps-helper traefik-tuning)"; fail=$((fail+1))
        fi
    fi

    chk_sect "Mises à jour automatiques"
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        chk_pass "unattended-upgrades actif"; pass=$((pass+1))
    else
        chk_fail "unattended-upgrades inactif"; fail=$((fail+1))
    fi

    check_sysctl
    check_system

    chk_sect "Informations (non bloquantes)"
    chk_info "Port SSH : $(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | paste -sd' ')"
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        chk_info "Swap : présent"
    else
        chk_info "Swap : absent"
    fi
    if ufw status numbered 2>/dev/null | grep -q '3000/tcp'; then
        chk_info "Port 3000 : ouvert (à fermer après configuration Dokploy)"
    else
        chk_info "Port 3000 : fermé"
    fi
    local swarm_state
    swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "N/A")
    chk_info "Docker Swarm : ${swarm_state}"

    printf '\n'
    if [[ "${fail}" -eq 0 ]]; then
        printf '%b\n' "${C_GREEN}${C_BOLD}Résultat : ${pass} vérification(s) passée(s), 0 échec, ${CHK_WARN_N} avertissement(s).${C_RESET}"
    else
        printf '%b\n' "${C_YELLOW}${C_BOLD}Résultat : ${pass} passée(s), ${fail} échec(s), ${CHK_WARN_N} avertissement(s) — voir FAIL ci-dessus.${C_RESET}"
    fi
    printf '\n'

    # Appelé aussi à 0 échec : c'est ce qui permet de signaler le retour au vert.
    if [ "$notify" -eq 1 ]; then
        check_notify_failures
    fi
}

case "$CMD" in
    status)         cmd_status ;;
    whitelist)      shift; cmd_whitelist "$@" ;;
    unban)          shift; cmd_unban "$@" ;;
    close-dokploy)  cmd_close_dokploy ;;
    ssh-keys)       shift; cmd_ssh_keys "$@" ;;
    restart)        shift; cmd_restart "$@" ;;
    logs)           shift; cmd_logs "$@" ;;
    update)         cmd_update ;;
    check)          shift; cmd_check "$@" ;;
    traefik-tuning) cmd_traefik_tuning ;;
    docker-firewall) shift; cmd_docker_firewall "$@" ;;
    notify-test)    shift; cmd_notify_test "$@" ;;
    notify-set)     cmd_notify_set ;;
    reboot-auto)    shift; cmd_reboot_auto "$@" ;;
    reboot-skip)    cmd_reboot_skip ;;
    reboot-status)  cmd_reboot_status ;;
    version)        cmd_version ;;
    help|--help|-h) print_help ;;
    *)
        err "Commande inconnue : « ${CMD} »."
        print_help
        exit 1
        ;;
esac
HELPEREOF
    sed -i "s/^INIT_VPS_VERSION=.*/INIT_VPS_VERSION=\"${SCRIPT_VERSION}\"/" /usr/local/bin/vps-helper
    sed -i "s/^DEFAULT_ADMIN_USER=.*/DEFAULT_ADMIN_USER=\"${ADMIN_USER}\"/" /usr/local/bin/vps-helper
    chmod +x /usr/local/bin/vps-helper
    log_ok "Commande vps-helper installée (vps-helper help pour la liste des commandes)."
}

###############################################################################
# 15. LIMITATION DES LOGS DOCKER
###############################################################################
step_docker_log_limits() {
    log_step "Limitation des logs Docker"
    mkdir -p /etc/docker

    local needs_restart=0
    if [[ ! -f /etc/docker/daemon.json ]] || ! grep -q '"max-size"' /etc/docker/daemon.json 2>/dev/null; then
        backup_file /etc/docker/daemon.json
        cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
        needs_restart=1
    fi

    if [[ "$needs_restart" -eq 0 ]]; then
        log_info "Limitation des logs Docker déjà en place."
        return
    fi

    if command -v docker &>/dev/null; then
        systemctl restart docker
        log_ok "Logs Docker limités à 10 Mo x 3 fichiers par conteneur (Docker redémarré pour appliquer)."
    else
        log_ok "Logs Docker limités à 10 Mo x 3 fichiers par conteneur (sera appliqué dès l'installation de Docker)."
    fi
}

###############################################################################
# 16. PARE-FEU DES PORTS PUBLIÉS PAR DOCKER (chaîne DOCKER-USER)
###############################################################################
# UFW ne filtre PAS les ports publiés par Docker : le trafic vers un conteneur
# traverse FORWARD (DOCKER-USER, DOCKER-FORWARD) sans jamais passer par les
# chaînes ufw-*. Mesuré en production : 102M paquets vus par DOCKER-USER,
# 0 par toutes les chaînes ufw-*forward. Sans pare-feu externe (Hetzner Cloud
# Firewall & assimilés, invisibles depuis le serveur), tout « -p 0.0.0.0:PORT »
# est donc exposé à Internet, sans que rien ne le signale.
#
# DOCKER-USER est le point d'accroche officiel prévu par Docker : il est
# évalué avant les règles générées par le démon, survit aux redémarrages, et
# — contrairement à ufw-docker — ne casse ni l'ingress Swarm ni
# docker_gwbridge, puisqu'on ne DROP que ce qui entre par l'interface publique.
#
# L'étape est préventive : à la première installation aucun conteneur n'existe
# encore, il n'y a donc rien à casser. En mode mise à jour, couper un port
# publié en production est un risque réel — on demande confirmation.
DOCKER_USER_DIR=/usr/local/lib/docker-user
DOCKER_USER_APPLY="${DOCKER_USER_DIR}/apply.sh"
DOCKER_USER_UNIT=/etc/systemd/system/docker-user-rules.service

# Ports publiés sur 0.0.0.0 / [::], un « port/proto » par ligne, dédoublonnés.
# `done < <(...)` et non un pipe : la boucle doit s'exécuter dans le shell
# courant, pas dans un sous-shell.
docker_published_public_ports() {
    command -v docker &>/dev/null || return 0
    local line chunk hostport proto
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local -a chunks=()
        IFS=',' read -ra chunks <<< "$line"
        for chunk in "${chunks[@]}"; do
            chunk="${chunk// /}"
            [[ "$chunk" == *'->'* ]] || continue
            # 0.0.0.0:/[::]: pour un conteneur, *: pour un service Swarm.
            [[ "$chunk" == 0.0.0.0:* || "$chunk" == '[::]:'* || "$chunk" == '*:'* ]] || continue
            hostport="${chunk%%->*}"
            hostport="${hostport##*:}"
            proto="${chunk##*/}"
            echo "${hostport}/${proto}"
        done
    done < <(docker_port_sources) | sort -u
}

# Deux sources, car aucune n'est complète : un service Swarm publié en mode
# ingress n'apparaît PAS dans `docker ps` (son conteneur de tâche ne montre
# que ses ports internes, ex. « 3000/tcp » pour Dokploy) — seul
# `docker service ls` le liste, sous la forme « *:3000->3000/tcp ». À
# l'inverse, un conteneur hors Swarm n'existe que dans `docker ps`.
docker_port_sources() {
    docker ps --format '{{.Ports}}' 2>/dev/null || true
    docker service ls --format '{{.Ports}}' 2>/dev/null || true
}

# La chaîne DOCKER-USER existe toujours (Docker la crée), mais `-N` seul ne
# filtre rien : c'est la présence de règles qui compte.
docker_user_rules() {
    iptables -S DOCKER-USER 2>/dev/null | grep -v '^-N ' || true
}

docker_user_chain_is_empty() {
    [[ -z "$(docker_user_rules)" ]]
}

# Règles posées par init-vps ? Elles portent toutes le commentaire iptables
# « init-vps », ce qui permet de les distinguer de règles tierces.
docker_user_has_foreign_rules() {
    local rules
    rules="$(docker_user_rules)"
    [[ -n "$rules" ]] && ! grep -q -- '--comment init-vps' <<< "$rules"
}

step_docker_user_firewall() {
    log_step "Pare-feu des ports publiés par Docker (DOCKER-USER)"

    if ! command -v iptables &>/dev/null; then
        log_info "iptables absent (Docker pas encore installé) : étape reportée au prochain lancement."
        return
    fi

    # Le script et l'unit sont toujours (ré)écrits : sans activation ils sont
    # inertes, et les avoir sur disque permet de pointer une commande réelle
    # à l'utilisateur quand l'application est refusée ou bloquée.
    install -d -m 0755 "$DOCKER_USER_DIR"
    backup_file "$DOCKER_USER_APPLY"
    cat > "$DOCKER_USER_APPLY" <<'APPLYEOF'
#!/usr/bin/env bash
# Généré par init-vps.sh — ne pas éditer à la main (réécrit à chaque exécution).
# Remplit la chaîne DOCKER-USER, évaluée par Docker AVANT ses propres règles
# de forwarding : c'est le seul endroit qui filtre réellement les ports
# publiés par les conteneurs (UFW, lui, ne les voit pas).
set -euo pipefail

# Interface publique = celle de la route par défaut. Détectée à chaque
# exécution (et non figée à l'installation) pour survivre à un changement de
# nom d'interface ou de route.
IFACE="$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit }}')"
if [ -z "$IFACE" ]; then
    echo "docker-user: aucune route par défaut, interface publique introuvable — aucune règle appliquée." >&2
    exit 0
fi

COMMENT=(-m comment --comment init-vps)

# Idempotence : la chaîne est vidée avant d'être réécrite.
iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER

# Réponses aux connexions sortantes des conteneurs.
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED "${COMMENT[@]}" -j RETURN

# Services web publics.
iptables -A DOCKER-USER -i "$IFACE" -p tcp --dport 80 "${COMMENT[@]}" -j RETURN
iptables -A DOCKER-USER -i "$IFACE" -p tcp --dport 443 "${COMMENT[@]}" -j RETURN
iptables -A DOCKER-USER -i "$IFACE" -p udp --dport 443 "${COMMENT[@]}" -j RETURN

# Réseaux privés (réseau interne du provider, VPN, autres nœuds Swarm).
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    iptables -A DOCKER-USER -i "$IFACE" -s "$net" "${COMMENT[@]}" -j RETURN
done

# Tout le reste venant de l'extérieur est rejeté. Le trafic qui n'entre pas
# par l'interface publique (conteneur à conteneur, docker_gwbridge, ingress
# Swarm) n'atteint jamais ce DROP.
iptables -A DOCKER-USER -i "$IFACE" "${COMMENT[@]}" -j DROP
iptables -A DOCKER-USER "${COMMENT[@]}" -j RETURN

# --- Miroir IPv6 --------------------------------------------------------------
# Tant que l'IPv6 est désactivé dans Docker, les ports publiés sont servis en
# v6 par docker-proxy (chaîne INPUT, donc filtrée par UFW) : ces règles sont
# alors sans effet. Mais activer « ipv6 » dans daemon.json ferait passer ce
# trafic par FORWARD — sans elles, tous les ports publiés y seraient nus.
command -v ip6tables >/dev/null 2>&1 || exit 0
ip6tables -S >/dev/null 2>&1 || exit 0
IFACE6="$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit }}')"
[ -n "$IFACE6" ] || exit 0

# Même règle qu'en IPv4 : des règles tierces ne sont jamais écrasées.
if ip6tables -S DOCKER-USER 2>/dev/null | grep '^-A' | grep -qv -- '--comment init-vps'; then
    echo "docker-user: règles IPv6 tierces dans DOCKER-USER — miroir IPv6 non appliqué." >&2
    exit 0
fi

ip6tables -N DOCKER-USER 2>/dev/null || true
ip6tables -F DOCKER-USER
ip6tables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED "${COMMENT[@]}" -j RETURN
ip6tables -A DOCKER-USER -i "$IFACE6" -p tcp --dport 80 "${COMMENT[@]}" -j RETURN
ip6tables -A DOCKER-USER -i "$IFACE6" -p tcp --dport 443 "${COMMENT[@]}" -j RETURN
ip6tables -A DOCKER-USER -i "$IFACE6" -p udp --dport 443 "${COMMENT[@]}" -j RETURN
# Équivalent v6 des réseaux privés : adresses ULA.
ip6tables -A DOCKER-USER -i "$IFACE6" -s fc00::/7 "${COMMENT[@]}" -j RETURN
ip6tables -A DOCKER-USER -i "$IFACE6" "${COMMENT[@]}" -j DROP
ip6tables -A DOCKER-USER "${COMMENT[@]}" -j RETURN
APPLYEOF
    chmod +x "$DOCKER_USER_APPLY"

    backup_file "$DOCKER_USER_UNIT"
    cat > "$DOCKER_USER_UNIT" <<'UNITEOF'
[Unit]
Description=Regles iptables DOCKER-USER (init-vps)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/docker-user/apply.sh

[Install]
WantedBy=multi-user.target
UNITEOF
    systemctl daemon-reload

    local rules_present=0
    docker_user_chain_is_empty || rules_present=1

    if docker_user_has_foreign_rules; then
        log_warn "La chaîne DOCKER-USER contient déjà des règles qui ne viennent pas d'init-vps : rien n'est appliqué pour ne pas les écraser."
        log_warn "Les inspecter (« iptables -S DOCKER-USER »), puis, si elles sont remplaçables : systemctl enable --now docker-user-rules.service"
        return
    fi

    # Première installation : aucun conteneur ne tourne, le risque est nul.
    # Mode mise à jour : lister d'abord ce que les règles couperaient.
    if [[ "$UPDATE_MODE" -eq 1 ]]; then
        local -a cut_ports=()
        local p
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            case "$p" in 80/tcp|443/tcp|443/udp) continue ;; esac
            cut_ports+=("$p")
        done < <(docker_published_public_ports)

        if [[ "${#cut_ports[@]}" -gt 0 ]]; then
            # Distinguer les deux situations : demander « appliquer quand même ? »
            # alors que la chaîne est DÉJÀ remplie laisse croire qu'un refus
            # rétablirait l'accès, alors qu'il ne fait que sauter une
            # réapplication à l'identique — les ports sont bloqués dans les deux
            # cas. La question n'est posée que si l'état change réellement.
            if [[ "$rules_present" -eq 1 ]]; then
                log_info "Ports publiés déjà bloqués depuis Internet par les règles en place (réapplication sans effet sur eux) :"
                for p in "${cut_ports[@]}"; do
                    log_info "    - ${p}"
                done
                log_info "Pour rétablir leur accès : sudo vps-helper docker-firewall clear (retire tout le filtrage)."
            else
                log_warn "Des conteneurs publient des ports qui deviendraient inaccessibles depuis Internet :"
                for p in "${cut_ports[@]}"; do
                    log_warn "    - ${p}"
                done
                log_info "Ces ports resteraient joignables depuis les réseaux privés (10/8, 172.16/12, 192.168/16)."
                if ! confirm "Appliquer quand même les règles DOCKER-USER ?" "n"; then
                    log_warn "Règles non appliquées. Pour le faire plus tard : sudo systemctl enable --now docker-user-rules.service"
                    return
                fi
            fi
        fi
    fi

    systemctl enable docker-user-rules.service >/dev/null 2>&1 || true

    # À la première installation, Docker n'est pas encore là : l'unit ne peut
    # pas démarrer (Requires=docker.service) mais la chaîne, elle, peut déjà
    # être remplie — iptables -N la crée, et le démon Docker ne vide jamais
    # DOCKER-USER au démarrage. C'est précisément l'intérêt de poser ces
    # règles maintenant : les conteneurs installés juste après (Dokploy,
    # Traefik) naissent déjà derrière le filtre, sans fenêtre d'exposition.
    if systemctl list-unit-files docker.service >/dev/null 2>&1 \
        && systemctl list-unit-files docker.service 2>/dev/null | grep -q '^docker\.service'; then
        # `restart` et non `start` : avec RemainAfterExit, une unit déjà
        # active ne rejouerait pas le script et les règles ne seraient pas
        # rafraîchies.
        systemctl restart docker-user-rules.service
    else
        "$DOCKER_USER_APPLY"
    fi
    log_ok "Règles DOCKER-USER appliquées (80, 443/tcp, 443/udp et réseaux privés autorisés ; le reste bloqué)."
}

###############################################################################
# 17. AUDIT DES PORTS PUBLIÉS PAR DOCKER (lecture seule)
###############################################################################
# Purement informatif : aucune correction automatique. Couper un port publié
# sur un serveur en production serait plus dangereux que de le signaler — la
# décision revient à l'exploitant. Sans valeur à la première installation
# (aucun conteneur n'existe), l'étape prend son sens en mode mise à jour et
# via « vps-helper check ».
step_docker_ports_audit() {
    log_step "Audit des ports publiés par Docker"

    if ! command -v docker &>/dev/null; then
        log_info "Docker absent, aucun port à auditer."
        return
    fi

    local found=0 p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        case "$p" in 80/tcp|443/tcp|443/udp) continue ;; esac
        log_warn "Port ${p} publié sur toutes les interfaces (conteneur ou service Swarm)."
        found=1
    done < <(docker_published_public_ports)

    if [[ "$found" -eq 0 ]]; then
        log_ok "Aucun port publié sur toutes les interfaces en dehors de 80/443."
    else
        log_info "Aucune correction automatique : arbitrer port par port (publier sur 127.0.0.1 plutôt que 0.0.0.0, ou laisser DOCKER-USER filtrer)."
    fi

    if command -v iptables &>/dev/null && docker_user_chain_is_empty; then
        log_warn "La chaîne DOCKER-USER est vide : UFW ne filtrant pas les ports publiés par Docker, la protection ne dépend plus que d'un éventuel pare-feu externe (Hetzner Cloud Firewall & assimilés), invisible depuis ce serveur."
    fi
}

###############################################################################
# 18. INSTALLATION DOKPLOY
###############################################################################
# Pré-installe Docker avant Dokploy. L'install.sh de Dokploy délègue à
# get.docker.com, qui déduit le nom de code APT depuis /etc/os-release : sur une
# version d'Ubuntu/Debian trop récente (ex. 26.04 « resolute »), le dépôt Docker
# n'existe pas encore et l'installation échoue (« docker: not found »). On
# installe donc Docker nous-mêmes en repliant sur la dernière LTS supportée si
# le dépôt du codename courant est absent. Une fois Docker présent, Dokploy le
# détecte et saute cette étape.
ensure_docker() {
    if command -v docker &>/dev/null; then
        log_info "Docker déjà présent, pré-installation ignorée."
    else
        log_info "Pré-installation de Docker (avant Dokploy)..."

        local id codename
        id="$( . /etc/os-release; echo "${ID:-ubuntu}" )"
        codename="$( . /etc/os-release; echo "${VERSION_CODENAME:-}" )"
        [[ "$id" == "ubuntu" || "$id" == "debian" ]] || id="ubuntu"

        local repo_base="https://download.docker.com/linux/${id}"
        if [[ -z "$codename" ]] || ! curl -fsSL "${repo_base}/dists/${codename}/Release" >/dev/null 2>&1; then
            local fallback
            if [[ "$id" == "debian" ]]; then fallback="bookworm"; else fallback="noble"; fi
            log_warn "Dépôt Docker indisponible pour « ${codename:-inconnu} », repli sur « ${fallback} »."
            codename="$fallback"
        fi

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "${repo_base}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${repo_base} ${codename} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null

        if ! command -v docker &>/dev/null; then
            error "Échec de l'installation de Docker (dépôt ${id}/${codename}). Dokploy ne peut pas être installé."
        fi
        log_ok "Docker installé (dépôt ${id}/${codename})."
    fi

    # Nécessaire ici (et pas seulement dans step_dokploy) : sur un serveur
    # « remote », ensure_docker est le SEUL point d'entrée Docker (step_dokploy
    # n'est jamais appelée), donc c'est ici qu'il faut garantir l'accès docker
    # sans sudo pour l'admin, sous peine de laisser ce rôle sans ce confort.
    usermod -aG docker "$ADMIN_USER" 2>/dev/null || true
}

step_dokploy() {
    log_step "Installation de Dokploy (Docker + Swarm inclus)"

    if command -v docker &>/dev/null && docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q '^active$'; then
        log_warn "Docker Swarm déjà actif sur ce serveur — Dokploy semble déjà installé, étape ignorée."
        usermod -aG docker "$ADMIN_USER" 2>/dev/null || true
        detect_server_ip
        log_ok "Dokploy déjà présent, rien à réinstaller."
        return
    fi

    while fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        log_warn "apt/dpkg occupé (ex: unattended-upgrades), nouvelle tentative dans 5s..."
        sleep 5
    done

    if [[ -z "$ADVERTISE_ADDR" ]]; then
        ADVERTISE_ADDR=$(hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1 || true)
    fi
    if [[ -n "$ADVERTISE_ADDR" ]]; then
        export ADVERTISE_ADDR
        log_info "ADVERTISE_ADDR utilisé pour Docker Swarm : ${ADVERTISE_ADDR}"
    else
        log_warn "Adresse réseau non détectée automatiquement, Dokploy tentera sa propre détection."
    fi

    ensure_docker

    curl -fsSL https://dokploy.com/install.sh | sh

    usermod -aG docker "$ADMIN_USER"
    detect_server_ip
    log_ok "Dokploy installé."
}

###############################################################################
# 19. OPTIMISATION TRAEFIK (HTTP/3 + compression) — patch idempotent
#
# Active HTTP/3 et une compression Brotli/Zstd/gzip sur la config Traefik gérée
# par Dokploy. La logique réelle vit dans vps-helper (cmd_traefik_tuning) : on
# la réutilise ici pour éviter toute duplication. vps-helper est déjà installé
# à ce stade (step_vps_helper s'exécute avant step_dokploy).
###############################################################################
step_traefik_tuning() {
    log_step "Optimisation Traefik (HTTP/3 + compression Brotli/Zstd)"
    if [[ ! -f /etc/dokploy/traefik/traefik.yml ]]; then
        log_warn "traefik.yml introuvable (Dokploy non installé ?) — étape ignorée."
        return
    fi
    if [[ -x /usr/local/bin/vps-helper ]]; then
        /usr/local/bin/vps-helper traefik-tuning \
            || log_warn "Optimisation Traefik incomplète (voir les messages ci-dessus)."
    else
        log_warn "vps-helper introuvable — optimisation Traefik ignorée."
    fi
}

###############################################################################
# 20. NOTIFICATIONS (webhook)
###############################################################################
# Constaté : rien ne notifiait jamais rien — ni un OOM, ni une unit en échec,
# ni un disque plein, ni unattended-upgrades en erreur, ni un reboot requis
# depuis trois semaines. Plutôt qu'un système d'alerte parallèle, on branche
# le webhook sur ce qui sait déjà détecter tout ça : `vps-helper check`
# (timer quotidien), plus OnFailure= sur unattended-upgrades.
step_notify() {
    log_step "Notifications"

    # vps-notify et l'unit d'échec sont toujours installés : sans webhook ils
    # sont inertes, et les units OnFailure= qui les référencent restent valides.
    backup_file /usr/local/bin/vps-notify
    cat > /usr/local/bin/vps-notify <<'NOTIFYEOF'
#!/usr/bin/env bash
# vps-notify — envoie une notification au webhook configuré. Généré par init-vps.sh.
#
#   vps-notify [--level fail|warn|ok|info] [--edit ID] [--print-id] "Titre" ["Détail"]
#   vps-notify --unit <unit>        (échec d'une unit : fin de son journal)
#
# Un même webhook sert tous les serveurs : sur Discord, chaque message est un
# embed portant le nom, le rôle et l'IP du serveur.
# Règle anti-bruit : fail/warn notifient ; ok/info arrivent en silencieux
# (flag SUPPRESS_NOTIFICATIONS) ; --edit modifie un message existant, ce qui
# ne notifie jamais. --print-id affiche l'ID du message créé (Discord).
# Codes de sortie : 0 envoyé · 1 échec d'envoi · 2 usage · 3 aucun webhook.
set -uo pipefail
export LC_ALL=C.UTF-8
ENV_FILE=/etc/init-vps/notify.env
STATE_FILE=/etc/init-vps/config.env

level=info edit_id="" print_id=0 unit=""
while [ $# -gt 0 ]; do
    case "$1" in
        --level|--edit|--unit)
            if [ $# -lt 2 ]; then
                echo "vps-notify : valeur manquante pour $1." >&2
                exit 2
            fi
            case "$1" in
                --level) level="$2" ;;
                --edit)  edit_id="$2" ;;
                --unit)  unit="$2" ;;
            esac
            shift 2
            ;;
        --print-id) print_id=1; shift ;;
        --) shift; break ;;
        -*) echo "vps-notify : option inconnue « $1 »." >&2; exit 2 ;;
        *) break ;;
    esac
done
case "$level" in
    fail|warn|ok|info) ;;
    *) echo "vps-notify : niveau inconnu « ${level} »." >&2; exit 2 ;;
esac
if [ -n "$edit_id" ] && ! [[ "$edit_id" =~ ^[0-9]+$ ]]; then
    echo "vps-notify : ID de message invalide." >&2
    exit 2
fi

if [ -n "$unit" ]; then
    level=fail
    title="Échec de ${unit}"
    body="$(journalctl -u "$unit" -n 15 --no-pager -o cat 2>/dev/null)"
else
    if [ $# -lt 1 ]; then
        echo "Usage : vps-notify [--level fail|warn|ok|info] [--edit ID] [--print-id] \"Titre\" [\"Détail\"]" >&2
        exit 2
    fi
    title="$1"
    body="${2:-}"
fi

if [ ! -r "$ENV_FILE" ]; then
    echo "vps-notify : aucun webhook configuré (${ENV_FILE}) — sudo vps-helper notify-set" >&2
    exit 3
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
if [ -z "${NOTIFY_WEBHOOK_URL:-}" ]; then
    echo "vps-notify : NOTIFY_WEBHOOK_URL vide — sudo vps-helper notify-set" >&2
    exit 3
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "vps-notify : python3 requis (construction du JSON)." >&2
    exit 1
fi

# vps-helper colore sa sortie : séquences ANSI et caractères de contrôle retirés.
clean() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\000-\010\013\014\016-\037'
}

case "$(grep -oP '^SERVER_ROLE="\K[12]' "$STATE_FILE" 2>/dev/null)" in
    1) role="Manager Dokploy" ;;
    2) role="Remote server" ;;
    *) role="—" ;;
esac
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
version="$(/usr/local/bin/vps-helper version 2>/dev/null)"
case "$NOTIFY_WEBHOOK_URL" in
    *discord.com/api/webhooks/*|*discordapp.com/api/webhooks/*) kind=discord ;;
    *) kind=other ;;
esac

# JSON construit par python3 : échappement correct de tout contenu (journal
# d'une unit, noms de conteneurs…), sans bricolage de chaînes en bash.
payload="$(TITLE="$(clean "$title")" BODY="$(clean "$body")" LEVEL="$level" CODE="${unit:+1}" \
    HOST="$(hostname)" ROLE="$role" IP="${ip:-?}" VERSION="${version:-?}" KIND="$kind" EDIT="$edit_id" \
    python3 -c '
import datetime, json, os
e = os.environ
icons = {"fail": "🔴", "warn": "🟠", "ok": "✅", "info": "🔵"}
colors = {"fail": 0xE74C3C, "warn": 0xE67E22, "ok": 0x2ECC71, "info": 0x3498DB}
title = (icons[e["LEVEL"]] + " " + e["TITLE"])[:256]
body = e["BODY"]
if e["CODE"] and body:
    body = "```\n" + body[-3800:] + "\n```"
body = body[:4000]
if e["KIND"] == "discord":
    embed = {
        "author": {"name": e["HOST"]},
        "title": title,
        "color": colors[e["LEVEL"]],
        "fields": [
            {"name": "Rôle", "value": e["ROLE"], "inline": True},
            {"name": "IP", "value": e["IP"], "inline": True},
        ],
        "footer": {"text": "init-vps " + e["VERSION"]},
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    if body:
        embed["description"] = body
    payload = {"username": "init-vps", "embeds": [embed], "allowed_mentions": {"parse": []}}
    # 4096 = SUPPRESS_NOTIFICATIONS : visible dans le salon, sans notification.
    # Jamais sur une modification : Discord le refuse, et elle ne notifie pas.
    if e["LEVEL"] in ("ok", "info") and not e["EDIT"]:
        payload["flags"] = 4096
else:
    payload = {"text": "*[" + e["HOST"] + "]* " + title + ("\n" + body if body else "")}
print(json.dumps(payload, ensure_ascii=False))
')" || exit 1

post() {
    curl -fsS --max-time 15 -H 'Content-Type: application/json' "$@"
}

if [ "$kind" != "discord" ]; then
    # Hors Discord, pas de modification possible : un nouveau message.
    post -d "$payload" "$NOTIFY_WEBHOOK_URL" >/dev/null || exit 1
    exit 0
fi

# Webhook éventuellement ciblé sur un fil (?thread_id=…) : la requête est
# reportée sur les URL de création comme de modification.
base="${NOTIFY_WEBHOOK_URL%%\?*}"
query=""
case "$NOTIFY_WEBHOOK_URL" in *\?*) query="${NOTIFY_WEBHOOK_URL#*\?}" ;; esac

if [ -n "$edit_id" ]; then
    post -X PATCH -d "$payload" "${base}/messages/${edit_id}${query:+?${query}}" >/dev/null || exit 1
    exit 0
fi

resp="$(post -d "$payload" "${base}?${query:+${query}&}wait=true")" || exit 1
if [ "$print_id" -eq 1 ]; then
    printf '%s' "$resp" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null
fi
exit 0
NOTIFYEOF
    chmod 750 /usr/local/bin/vps-notify

    # « - » devant ExecStart : sans webhook, l'échec d'envoi ne doit pas créer
    # une unit en échec de plus — que `check` signalerait à son tour.
    cat > /etc/systemd/system/vps-notify-failure@.service <<'EOF'
[Unit]
Description=Notification d'échec de %i (init-vps)

[Service]
Type=oneshot
ExecStart=-/usr/local/bin/vps-notify --unit %i
EOF

    mkdir -p /etc/systemd/system/apt-daily-upgrade.service.d
    cat > /etc/systemd/system/apt-daily-upgrade.service.d/init-vps-notify.conf <<'EOF'
[Unit]
OnFailure=vps-notify-failure@%n.service
EOF

    cat > /etc/systemd/system/vps-check.service <<'EOF'
[Unit]
Description=Audit vps-helper check, échecs envoyés au webhook (init-vps)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-helper check --notify
EOF

    cat > /etc/systemd/system/vps-check.timer <<'EOF'
[Unit]
Description=Audit quotidien vps-helper check (init-vps)

[Timer]
OnCalendar=*-*-* 08:00:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload

    if [[ "$NOTIFY_ENABLED" != "1" ]]; then
        systemctl disable --now vps-check.timer >/dev/null 2>&1 || true
        log_info "Notifications non configurées (vps-notify installé mais inerte ; activer plus tard : sudo vps-helper notify-set)."
        return
    fi

    # vps-notify construit son JSON avec python3 (présent de base sur Ubuntu).
    if ! command -v python3 &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null 2>&1 \
            || log_warn "python3 absent et non installable : vps-notify ne pourra rien envoyer."
    fi

    if [[ -f "$NOTIFY_ENV_FILE" ]]; then
        log_info "Webhook existant conservé (${NOTIFY_ENV_FILE})."
    elif [[ -z "$NOTIFY_WEBHOOK_URL" ]]; then
        log_warn "Notifications activées mais aucun webhook saisi : étape ignorée."
        return
    else
        mkdir -p "$STATE_DIR"
        (umask 077; printf 'NOTIFY_WEBHOOK_URL=%q\n' "$NOTIFY_WEBHOOK_URL" > "$NOTIFY_ENV_FILE")
        NOTIFY_WEBHOOK_URL=""
        log_ok "Webhook enregistré dans ${NOTIFY_ENV_FILE} (600, root uniquement)."
        if /usr/local/bin/vps-notify --level info "Notifications activées" "Ce serveur enverra ses alertes dans ce salon."; then
            log_ok "Notification de test envoyée (silencieuse)."
        else
            log_warn "Envoi de test en échec : vérifier l'URL, puis sudo vps-helper notify-test"
        fi
    fi

    systemctl enable --now vps-check.timer >/dev/null 2>&1
    log_ok "Audit quotidien actif (vps-check.timer) : les échecs de vps-helper check et d'unattended-upgrades sont notifiés."
}

###############################################################################
# 22. REDÉMARRAGE AUTOMATIQUE (optionnel) — après step_save_state
###############################################################################
# Mesuré en production : un redémarrage requis attendait depuis trois
# semaines. Un ping seul dépend de quelqu'un qui le lit et agit.
#
# unattended-upgrades garde « Automatic-Reboot false » : son redémarrage
# intégré part sans préavis ni compte rendu. Tout le cycle (annonce, report,
# redémarrage dans la fenêtre, vérification des services au retour) vit dans
# vps-helper (`reboot-auto`) ; ces units ne font que le déclencher.
#
# Exécutée APRÈS step_save_state : `reboot-auto` lit AUTO_REBOOT et
# AUTO_REBOOT_TIME dans config.env, qui doit donc déjà être à jour.
step_auto_reboot() {
    log_step "Redémarrage automatique"
    local window="$AUTO_REBOOT_TIME" u
    validate_hhmm "$window" || window="04:00"

    cat > /etc/systemd/system/vps-reboot-notice.path <<'EOF'
[Unit]
Description=Détection d'un redémarrage requis (init-vps)

[Path]
PathExists=/run/reboot-required

[Install]
WantedBy=paths.target
EOF

    # RemainAfterExit : l'unit reste « active » jusqu'au reboot, sinon
    # PathExists= la relancerait en boucle tant que le fichier existe.
    # « - » : un échec d'envoi ne doit pas laisser une unit en échec.
    cat > /etc/systemd/system/vps-reboot-notice.service <<'EOF'
[Unit]
Description=Planification du redémarrage automatique (init-vps)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/usr/local/bin/vps-helper reboot-auto notice
EOF

    cat > /etc/systemd/system/vps-reboot-auto.service <<'EOF'
[Unit]
Description=Redémarrage automatique, si requis et planifié (init-vps)

[Service]
Type=oneshot
ExecStart=-/usr/local/bin/vps-helper reboot-auto run
EOF

    # Persistent=false : une fenêtre manquée (serveur éteint) ne doit pas
    # déclencher un redémarrage en pleine journée.
    cat > /etc/systemd/system/vps-reboot-auto.timer <<EOF
[Unit]
Description=Fenêtre de redémarrage automatique (init-vps)

[Timer]
OnCalendar=*-*-* ${window}:00
RandomizedDelaySec=30min
Persistent=false

[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/vps-reboot-report.service <<'EOF'
[Unit]
Description=Compte rendu après redémarrage automatique (init-vps)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=-/usr/local/bin/vps-helper reboot-auto report
EOF

    cat > /etc/systemd/system/vps-reboot-report.timer <<'EOF'
[Unit]
Description=Compte rendu 5 min après le démarrage (init-vps)

[Timer]
OnBootSec=5min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload

    if [[ "$AUTO_REBOOT" != "1" ]]; then
        for u in vps-reboot-notice.path vps-reboot-auto.timer vps-reboot-report.timer; do
            systemctl disable --now "$u" >/dev/null 2>&1 || true
        done
        rm -f /var/lib/init-vps/reboot-planned
        log_info "Redémarrage automatique désactivé : un redémarrage requis reste signalé par le MOTD et vps-helper check (échec au-delà de 7 jours)."
        return
    fi

    systemctl enable vps-reboot-report.timer >/dev/null 2>&1
    systemctl enable --now vps-reboot-auto.timer vps-reboot-notice.path >/dev/null 2>&1
    # Redémarrage déjà requis (ex. kernel du dist-upgrade initial) : planifié
    # tout de suite, sans attendre que l'unit path se déclenche. Idempotent.
    /usr/local/bin/vps-helper reboot-auto notice >/dev/null 2>&1 || true
    log_ok "Redémarrage automatique actif : fenêtre ${window} (± 30 min), annoncé au moins 12 h avant, report : vps-helper reboot-skip."
}

###############################################################################
# 21. SAUVEGARDE DE L'ÉTAT — pour le mode mise à jour (--update)
###############################################################################
# Persiste la configuration collectée pour permettre de relancer le script
# plus tard en mode mise à jour (rejoue les steps idempotents sans reposer
# les questions). Ne contient volontairement PAS les clés SSH : la gestion
# des clés se fait ensuite via `vps-helper ssh-keys`, l'authorized_keys du
# serveur reste la seule source de vérité.
step_save_state() {
    log_step "Sauvegarde de la configuration (pour les mises à jour futures)"
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
SCRIPT_VERSION="${SCRIPT_VERSION}"
SERVER_HOSTNAME="${SERVER_HOSTNAME}"
ADMIN_USER="${ADMIN_USER}"
TIMEZONE="${TIMEZONE}"
SWAP_SIZE_GB="${SWAP_SIZE_GB}"
DOKPLOY_RESTRICT_IP="${DOKPLOY_RESTRICT_IP}"
ADVERTISE_ADDR="${ADVERTISE_ADDR}"
SERVER_ROLE="${SERVER_ROLE}"
DOKPLOY_PORT_CLOSED="${DOKPLOY_PORT_CLOSED}"
SSH_PORT="${SSH_PORT}"
NOTIFY_ENABLED="${NOTIFY_ENABLED}"
AUTO_REBOOT="${AUTO_REBOOT}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME}"
LAST_RUN="$(date -Iseconds)"
EOF
    chmod 600 "$STATE_FILE"
    log_ok "Configuration sauvegardée dans ${STATE_FILE} (réutilisée par le mode mise à jour)."
}

###############################################################################
# RÉSUMÉ FINAL
###############################################################################
# Vrai si un redémarrage est nécessaire : soit le drapeau posé par apt
# (/var/run/reboot-required), soit un kernel plus récent installé mais pas
# encore chargé (fréquent après le dist-upgrade initial).
reboot_is_pending() {
    [[ -f /var/run/reboot-required ]] && return 0
    local running newest
    running="$(uname -r)"
    newest="$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null \
        | sed 's|.*/vmlinuz-||' | sort -V | tail -n1)"
    [[ -n "$newest" && "$newest" != "$running" ]]
}

# Un domaine est-il déjà configuré avec TLS dans Dokploy ?
# On lit acme.json (le magasin de certificats de Traefik) : chaque certificat
# émis y porte une clé "main" avec son domaine. Fichier root-only — le script
# tourne en root, mais on reste tolérant en cas d'absence ou de rôle remote.
dokploy_has_tls_domain() {
    local acme=/etc/dokploy/traefik/dynamic/acme.json
    [[ -s "$acme" ]] || return 1
    grep -q '"main"[[:space:]]*:' "$acme" 2>/dev/null
}

# Le port 3000 est-il encore joignable ? Deux sources de vérité, car aucune ne
# suffit seule :
#   - UFW, interrogé plutôt que $DOKPLOY_PORT_CLOSED : cette variable ne connaît
#     que les fermetures faites via `vps-helper close-dokploy`, pas un
#     `ufw delete` lancé à la main.
#   - les ports publiés par Docker : UFW ne les filtre pas (leur trafic passe
#     par DOCKER-USER/DOCKER-FORWARD, jamais par les chaînes ufw-*). Sur un
#     serveur réel, `check` annonçait « port 3000 fermé » alors que docker-proxy
#     écoutait sur 0.0.0.0:3000 — la règle UFW avait été supprimée, le port
#     restait bel et bien exposé.
dokploy_port_is_open() {
    ufw status 2>/dev/null | grep -q '3000/tcp' && return 0
    docker_published_public_ports 2>/dev/null | grep -qx '3000/tcp'
}

# Sépare deux étapes par une ligne vide, sauf avant la première : sinon la
# liste commence par un blanc dès qu'une étape amont est sautée.
# Lit $step_n de print_summary via la portée dynamique de bash.
step_sep() {
    [[ "${step_n:-1}" -gt 1 ]] && echo ""
    return 0
}

print_summary() {
    # Calculé ici (et non en début de script) pour éviter tout décalage avec
    # le fuseau horaire défini en cours de route (step_system_misc).
    SUMMARY_FILE="/root/init-vps-summary-$(date +%Y%m%d-%H%M%S).txt"

    # Compte les clés SSH réellement installées sur disque plutôt que le
    # tableau en mémoire : en mode mise à jour, SSH_PUBLIC_KEYS est vide
    # (les clés sont gérées via `vps-helper ssh-keys`), l'authorized_keys
    # du compte admin reste la seule source de vérité.
    local key_count="" authorized_keys="/home/${ADMIN_USER}/.ssh/authorized_keys"
    if [[ -f "$authorized_keys" ]]; then
        # grep -c imprime "0" ET sort en erreur (1) quand rien ne matche : ne
        # jamais mettre `|| echo 0` À L'INTÉRIEUR du $(...), ça concaténerait
        # les deux sorties ("0" + "0") au lieu de se substituer proprement.
        key_count=$(grep -c '^[^#[:space:]]' "$authorized_keys" 2>/dev/null || true)
    fi
    key_count="${key_count:-0}"

    {
        echo "════════════════════════════════════════════════════"
        echo " RÉSUMÉ — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "════════════════════════════════════════════════════"
        echo "Version init-vps  : ${SCRIPT_VERSION}"
        echo "Hostname          : ${SERVER_HOSTNAME}"
        echo "Compte admin      : ${ADMIN_USER}"
        echo "Port SSH          : ${SSH_PORT}"
        echo "Clé(s) SSH        : ${key_count} installée(s) (gestion : vps-helper ssh-keys)"
        # État réel du swap, pas la valeur demandée : $SWAP_SIZE_GB vaut 0 aussi
        # bien quand aucun swap n'a été voulu que lorsqu'un swap préexistant a
        # fait sauter l'étape. Afficher « aucun (ou déjà présent) » revenait à
        # dire qu'on ne sait pas — alors que `swapon` le sait.
        local swap_total
        swap_total=$(free -h 2>/dev/null | awk '/^Swap:/ {print $2}')
        if [[ -n "$swap_total" && "$swap_total" != "0B" && "$swap_total" != "0" ]]; then
            echo "Swap              : ${swap_total} actif"
        else
            echo "Swap              : aucun"
        fi
        # Même règle que le swap : l'état réel (fichier présent), pas la réponse.
        if [[ -f "$NOTIFY_ENV_FILE" ]]; then
            echo "Notifications     : webhook actif (vps-helper notify-test)"
        fi
        if systemctl is-enabled --quiet vps-reboot-auto.timer 2>/dev/null; then
            echo "Redémarrage auto  : si requis, vers ${AUTO_REBOOT_TIME} (vps-helper reboot-status)"
        fi
        if [[ "$SERVER_ROLE" == "1" ]]; then
            # Ne pas annoncer une URL qui ne répond plus : une fois le port
            # fermé, l'interface passe par le domaine configuré dans Dokploy.
            if dokploy_port_is_open; then
                echo "Dokploy           : http://${SERVER_IP}:3000"
            else
                echo "Dokploy           : installé — port 3000 fermé, accès par le domaine configuré"
            fi
        else
            echo "Rôle              : Remote server — prêt à être ajouté depuis Dokploy (Settings → Servers → Add Server)"
        fi
        echo "Fichier log       : ${LOG_FILE}"
        [[ -f "$PASSWORD_FILE" ]] && echo "Mot de passe sudo : ${PASSWORD_FILE} (à supprimer une fois noté)"
        if reboot_is_pending; then
            echo "Redémarrage       : REQUIS (nouveau kernel installé, pas encore chargé)"
        fi
        echo ""
        echo "PROCHAINES ÉTAPES"
        echo "──────────────────────────────────────────────────"

        # Chaque étape est conditionnée à son état réel : sur une relance en
        # mode mise à jour, réafficher la checklist d'une première installation
        # est du bruit, et le bruit finit par faire ignorer les vraies alertes
        # (le redémarrage requis, par exemple).
        local step_n=1 has_domain=0 port_open=0
        dokploy_has_tls_domain && has_domain=1
        dokploy_port_is_open && port_open=1

        # La connexion SSH n'a besoin d'être validée qu'après le verrouillage
        # initial. En mode mise à jour, elle l'est déjà — le script tourne
        # justement à travers elle.
        if [[ "$UPDATE_MODE" -eq 0 ]]; then
            echo "${step_n}. Vérifier la connexion SSH depuis un nouveau terminal :"
            echo "     $(ssh_cmd_hint "$SERVER_IP")"
            step_n=$((step_n+1))
        fi

        if [[ "$SERVER_ROLE" == "1" ]]; then
            if [[ "$has_domain" -eq 0 ]]; then
                step_sep
                echo "${step_n}. Pointer un nom de domaine vers ${SERVER_IP} (enregistrement DNS de type A)."
                step_n=$((step_n+1))
                step_sep
                echo "${step_n}. Dans Dokploy (http://${SERVER_IP}:3000), configurer le domaine et activer le TLS automatique."
                step_n=$((step_n+1))
            fi

            if [[ "$port_open" -eq 1 ]]; then
                step_sep
                if [[ "$has_domain" -eq 1 ]]; then
                    echo "${step_n}. Un domaine TLS est actif : fermer l'accès direct au port 3000."
                else
                    echo "${step_n}. Une fois le domaine actif, fermer l'accès direct au port 3000."
                fi
                # `vps-helper close-dokploy` et NON un `ufw delete` brut : lui
                # seul persiste le choix dans config.env. Un ufw delete manuel
                # serait rouvert par step_ufw_base à la prochaine relance.
                echo "     sudo vps-helper close-dokploy"
                step_n=$((step_n+1))
                step_sep
                echo "${step_n}. Désactiver l'accès direct via ip:port dans les réglages Dokploy."
                step_n=$((step_n+1))
            fi
        else
            step_sep
            echo "${step_n}. Ajouter ce serveur depuis le manager Dokploy : Settings → Servers → Add Server"
            echo "     IP : ${SERVER_IP} · Port SSH : ${SSH_PORT} · Utilisateur : ${ADMIN_USER}"
            step_n=$((step_n+1))
        fi

        if [[ -f "$PASSWORD_FILE" ]]; then
            step_sep
            echo "${step_n}. Supprimer le fichier mot de passe une fois noté :"
            echo "     shred -u ${PASSWORD_FILE}"
            step_n=$((step_n+1))
        fi

        if [[ "$step_n" -eq 1 ]]; then
            echo "Aucune action requise — le serveur est déjà entièrement configuré."
        fi

        if reboot_is_pending; then
            echo ""
            if [[ -f /var/lib/init-vps/reboot-planned ]]; then
                echo "⚠ Redémarrage requis : automatique le $(date -d "@$(cut -d' ' -f1 /var/lib/init-vps/reboot-planned)" '+%d/%m à %H:%M') (± 30 min). Pour le faire tout de suite :"
            else
                echo "⚠ Un nouveau kernel a été installé : redémarrer le serveur pour le charger :"
            fi
            echo "     reboot"
        fi
    } | tee "$SUMMARY_FILE" | tee -a "$LOG_FILE"

    echo ""
    log_ok "Résumé sauvegardé dans ${SUMMARY_FILE}"
}

offer_password_cleanup() {
    # `return` SANS code explicite reprend le statut de la dernière commande
    # exécutée — ici le `[[ -f ]]` qui vient d'échouer (1). Appelée en
    # instruction nue dans main(), une fonction qui "réussit en renvoyant 1"
    # déclenche `set -e` et tue tout le script silencieusement juste après
    # l'affichage du résumé final (bug historique, présent avant ce commit).
    [[ -f "$PASSWORD_FILE" ]] || return 0
    if confirm "Mot de passe sudo noté ? Suppression du fichier maintenant ?" "n"; then
        shred -u "$PASSWORD_FILE"
        log_ok "Fichier mot de passe supprimé."
    else
        log_warn "À supprimer ultérieurement : shred -u ${PASSWORD_FILE}"
    fi
}

# Options apparues dans une version du script plus récente que celle qui a
# provisionné ce serveur : leur clé est absente de $STATE_FILE. Le mode mise à
# jour ne repose que CES questions-là — jamais celles déjà répondues (un refus
# est mémorisé "0"). Exception : une option acceptée dont le fichier de
# secrets a disparu est reproposée, sans quoi elle resterait « activée » à vide.
ask_new_options() {
    if ! state_has SSH_PORT; then
        collect_ssh_port
    fi
    if ! state_has NOTIFY_ENABLED || { [[ "$NOTIFY_ENABLED" == "1" ]] && [[ ! -f "$NOTIFY_ENV_FILE" ]]; }; then
        collect_notify
    fi
    if ! state_has AUTO_REBOOT; then
        collect_auto_reboot
    fi
    return 0
}

###############################################################################
# EXÉCUTION
###############################################################################
main() {
    if [[ "${1:-}" == "--version" ]] || [[ "${1:-}" == "-v" ]]; then
        echo "$SCRIPT_VERSION"
        exit 0
    fi
    precheck_root
    precheck_tty
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    print_banner
    detect_os

    # --- Mode mise à jour -----------------------------------------------
    # Une exécution précédente laisse un état sauvegardé (${STATE_FILE}).
    # On le détecte pour proposer de rejouer les steps idempotentes (MOTD,
    # vps-helper, durcissement...) sans reposer les questions. `--update`
    # force ce mode explicitement (utile en non-interactif).
    local update_mode=0
    [[ "${1:-}" == "--update" ]] && update_mode=1

    if [[ -f "$STATE_FILE" ]]; then
        if [[ "$update_mode" -eq 0 ]]; then
            log_info "Configuration existante détectée (${STATE_FILE}, exécution précédente du script)."
            confirm "Lancer en mode mise à jour (réapplique MOTD, vps-helper, durcissement... sans reposer les questions) ?" "o" \
                && update_mode=1
        fi
    elif [[ "$update_mode" -eq 1 ]]; then
        error "Mode mise à jour demandé (--update) mais aucune configuration sauvegardée trouvée (${STATE_FILE}). Lancer d'abord une installation complète (sans --update)."
    fi

    UPDATE_MODE="$update_mode"

    if [[ "$update_mode" -eq 1 ]]; then
        # $STATE_FILE contient un SCRIPT_VERSION=... figé au moment de sa
        # sauvegarde (exécution précédente, potentiellement une version plus
        # ancienne du script). Le sourcer écraserait la version RÉELLEMENT en
        # cours d'exécution maintenant : on la sauvegarde avant, on la
        # restaure après, pour que vps-helper/print_summary/step_save_state
        # rapportent toujours la version du script qui tourne réellement.
        local running_script_version="$SCRIPT_VERSION"
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        SCRIPT_VERSION="$running_script_version"
        [[ -z "$SERVER_ROLE" ]] && SERVER_ROLE="1"
        SSH_PUBLIC_KEYS=()
        log_info "Configuration chargée : hostname=${SERVER_HOSTNAME}, admin=${ADMIN_USER}, rôle=$([[ "$SERVER_ROLE" == "1" ]] && echo manager || echo remote)."
        log_info "Gestion des clés SSH : utiliser « vps-helper ssh-keys » après cette exécution si besoin."
        ask_new_options
    else
        collect_hostname
        collect_admin_user
        collect_ssh_keys
        collect_ssh_port
        collect_timezone
        collect_swap
        collect_server_role
        if [[ "$SERVER_ROLE" == "1" ]]; then
            collect_dokploy_restrict_ip
            collect_advertise_addr
        fi
        collect_notify
        collect_auto_reboot
        show_recap

        confirm "Lancer l'initialisation avec ces paramètres ?" "o" \
            || { log_warn "Annulé par l'utilisateur."; exit 0; }
    fi

    detect_server_ip

    # En mode mise à jour, on ne relance pas un apt dist-upgrade complet à
    # chaque fois (déjà couvert par unattended-upgrades / vps-helper update) —
    # le mode mise à jour est documenté comme une réapplication légère de la
    # config (MOTD, vps-helper, durcissement...), pas une maintenance système.
    configure_needrestart

    if [[ "$update_mode" -eq 0 ]]; then
        step_update_system
    else
        log_info "Mode mise à jour : mise à jour système ignorée (voir unattended-upgrades / vps-helper update)."
    fi
    step_hostname
    step_create_admin
    step_fail2ban
    step_ssh_phase1
    step_ufw_base
    step_ssh_phase2
    step_lock_root
    step_unattended_upgrades
    step_sysctl_hardening
    step_swap
    step_system_misc
    step_motd
    step_vps_helper
    step_docker_log_limits
    # Les deux rôles publient des conteneurs : le filtrage DOCKER-USER et
    # l'audit des ports valent pour un manager comme pour un remote server.
    step_docker_user_firewall
    step_docker_ports_audit
    if [[ "$SERVER_ROLE" == "1" ]]; then
        step_dokploy
        step_traefik_tuning
    else
        log_info "Rôle 'remote server' : Dokploy ne sera pas installé ici, il sera ajouté depuis le manager central."
        ensure_docker
    fi
    step_notify
    step_save_state
    step_auto_reboot

    print_summary
    offer_password_cleanup

    log_ok "Initialisation terminée !"
}

main "$@"
