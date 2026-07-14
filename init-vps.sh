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
#  10. Durcissement sysctl réseau
#  11. Swap (taille recommandée selon la RAM détectée, ajustable)
#  12. Fuseau horaire / NTP / limites des logs journald
#  13. MOTD personnalisé (design uniforme à la connexion SSH)
#  14. Commande d'aide vps-helper (whitelist, ssh-keys, restart, logs, update...)
#  15. Limitation des logs Docker (rotation 10 Mo x 3 par conteneur)
#  16. Installation de Dokploy — uniquement si rôle = manager
#  17. Optimisation Traefik (HTTP/3 + compression Brotli/Zstd, patch idempotent)
#      — uniquement si rôle = manager
#  18. Sauvegarde de la configuration (/etc/init-vps/config.env), pour permettre
#      une future relance en mode mise à jour
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
SSH_PORT=22
SCRIPT_VERSION="0.0.0-dev"
LOG_FILE="/var/log/init-vps.log"
SSHD_HARDENING_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"
STATE_DIR="/etc/init-vps"
STATE_FILE="${STATE_DIR}/config.env"

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
PASSWORD_FILE=""
SERVER_IP=""
SUMMARY_FILE=""

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
    if swapon --show | grep -q '/swapfile'; then
        log_info "Un swapfile existe déjà sur ce serveur, cette étape sera ignorée."
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

show_recap() {
    log_step "Récapitulatif avant exécution"
    local swap_line dokploy_line advertise_line role_line
    [[ "$SWAP_SIZE_GB" -eq 0 ]] && swap_line="aucun" || swap_line="${SWAP_SIZE_GB} Go"
    [[ "$SERVER_ROLE" == "1" ]] && role_line="Manager Dokploy" || role_line="Remote server (géré à distance)"

    {
        echo "  Hostname                  : ${SERVER_HOSTNAME}"
        echo "  Compte admin              : ${ADMIN_USER}"
        echo "  Clé(s) SSH                : ${#SSH_PUBLIC_KEYS[@]} clé(s) fournie(s)"
        echo "  Port SSH                  : ${SSH_PORT} (fixe)"
        echo "  Fuseau horaire             : ${TIMEZONE}"
        echo "  Swap                      : ${swap_line}"
        echo "  Rôle du serveur           : ${role_line}"
        if [[ "$SERVER_ROLE" == "1" ]]; then
            [[ -n "$DOKPLOY_RESTRICT_IP" ]] && dokploy_line="restreint à ${DOKPLOY_RESTRICT_IP}" || dokploy_line="ouvert temporairement à tous"
            [[ -n "$ADVERTISE_ADDR" ]] && advertise_line="${ADVERTISE_ADDR}" || advertise_line="auto-détection (Dokploy)"
            echo "  Accès Dokploy (port 3000) : ${dokploy_line}"
            echo "  Adresse Docker Swarm       : ${advertise_line}"
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
# 1. MISE À JOUR SYSTÈME
###############################################################################
step_update_system() {
    log_step "Mise à jour du système et installation des paquets de base"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get dist-upgrade -y
    apt-get install -y curl wget gnupg ca-certificates software-properties-common \
        ufw fail2ban unattended-upgrades update-notifier-common needrestart htop openssl
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

step_ssh_phase1() {
    log_step "Configuration SSH — phase 1 (transition)"
    if ssh_already_hardened; then
        log_info "SSH déjà verrouillé (détecté), phase 1 ignorée pour ne pas rouvrir l'accès root par mot de passe."
        return
    fi
    backup_file "$SSHD_HARDENING_FILE"
    cat > "$SSHD_HARDENING_FILE" <<EOF
# Phase 1 : root et mot de passe encore autorisés, pour ne pas se retrouver
# bloqué hors du serveur pendant la transition vers le compte admin.
Port ${SSH_PORT}
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
    systemctl restart ssh
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
        log_warn "Port 3000 ouvert à tous. Fermeture manuelle requise une fois le domaine et le TLS configurés dans Dokploy (ufw delete allow 3000/tcp)."
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
        log_info "SSH déjà verrouillé, rien à faire."
        return
    fi

    local ip_hint
    ip_hint=$(curl -s -4 --max-time 3 ifconfig.me || echo '<IP_DU_SERVEUR>')

    echo ""
    log_warn "=== ÉTAPE DE VALIDATION OBLIGATOIRE ==="
    echo "Ouvrir un NOUVEAU terminal (sans fermer celui-ci) et tester la connexion :"
    echo ""
    echo -e "    ${C_GREEN}ssh ${ADMIN_USER}@${ip_hint}${C_RESET}"
    echo ""
    if [[ -f "$PASSWORD_FILE" ]]; then
        log_secret "Mot de passe sudo pour ${ADMIN_USER} : $(cat "$PASSWORD_FILE")"
        log_warn "À conserver si nécessaire (utile pour 'sudo -i')."
    fi
    echo "Vérifier également l'accès root via : sudo -i"
    echo ""

    confirm "La connexion avec ${ADMIN_USER} fonctionne et sudo est validé, verrouiller SSH maintenant ?" "n" \
        || error "Verrouillage SSH annulé. Relancer le script une fois prêt : les étapes déjà réalisées seront ignorées."

    backup_file "$SSHD_HARDENING_FILE"
    cat > "$SSHD_HARDENING_FILE" <<EOF
Port ${SSH_PORT}
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
    test_sshd_config
    systemctl restart ssh
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

    if grep -q "nrconf{restart}" /etc/needrestart/needrestart.conf 2>/dev/null; then
        sed -i "s/.*nrconf{restart}.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    else
        echo "\$nrconf{restart} = 'a';" >> /etc/needrestart/needrestart.conf
    fi

    systemctl enable unattended-upgrades >/dev/null 2>&1
    systemctl restart unattended-upgrades
    log_ok "Mises à jour de sécurité automatiques configurées (sans reboot auto)."
}

###############################################################################
# 10. DURCISSEMENT SYSCTL RÉSEAU
###############################################################################
step_sysctl_hardening() {
    log_step "Durcissement réseau (sysctl)"
    backup_file /etc/sysctl.d/99-hardening.conf
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
    # --system charge tous les fichiers ; on ignore les clés IPv6 absentes si
    # l'IPv6 est désactivé au boot (sysctl --system n'échoue pas là-dessus).
    sysctl --system >/dev/null 2>&1 || sysctl --system >/dev/null
    log_ok "Durcissement réseau appliqué (IPv4 + IPv6)."
}

###############################################################################
# 11. SWAP
###############################################################################
step_swap() {
    log_step "Création du swap"
    if [[ "$SWAP_SIZE_GB" -eq 0 ]]; then
        log_info "Swap ignoré (0 Go demandé, ou swap déjà présent)."
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

    backup_file /etc/sysctl.d/99-swap.conf
    cat > /etc/sysctl.d/99-swap.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    sysctl --system >/dev/null
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

chk_pass() { printf '%b %s\n' "${C_GREEN}[PASS]${C_RESET}" "$1"; }
chk_fail() { printf '%b %s\n' "${C_RED}[FAIL]${C_RESET}" "$1"; }
chk_info() { printf '%b %s\n' "${C_CYAN}[INFO]${C_RESET}" "$1"; }
chk_sect() { printf '\n%b%s%b\n' "${C_DIM}── " "$1" " ────────────────────────────────────────${C_RESET}"; }

NEED_ROOT_CMDS="whitelist unban close-dokploy restart update check traefik-tuning ssh-keys"
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

cmd_check() {
    local pass=0 fail=0

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
    if fail2ban-client status 2>/dev/null | grep 'Jail list:' | grep -q 'recidive'; then
        chk_pass "Jail recidive activée"; pass=$((pass+1))
    else
        chk_fail "Jail recidive non activée"; fail=$((fail+1))
    fi

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

    chk_sect "Informations (non bloquantes)"
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
    if [[ -f /var/run/reboot-required ]]; then
        chk_info "Redémarrage requis"
    else
        chk_info "Redémarrage non requis"
    fi
    local swarm_state
    swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "N/A")
    chk_info "Docker Swarm : ${swarm_state}"

    printf '\n'
    if [[ "${fail}" -eq 0 ]]; then
        printf '%b\n' "${C_GREEN}${C_BOLD}Résultat : ${pass} vérification(s) passée(s), 0 échec.${C_RESET}"
    else
        printf '%b\n' "${C_YELLOW}${C_BOLD}Résultat : ${pass} passée(s), ${fail} échec(s) — voir FAIL ci-dessus.${C_RESET}"
    fi
    printf '\n'
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
    check)          cmd_check ;;
    traefik-tuning) cmd_traefik_tuning ;;
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
# 16. INSTALLATION DOKPLOY
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
# 17. OPTIMISATION TRAEFIK (HTTP/3 + compression) — patch idempotent
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
# 18. SAUVEGARDE DE L'ÉTAT — pour le mode mise à jour (--update)
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
        if [[ "$SWAP_SIZE_GB" -eq 0 ]]; then
            echo "Swap              : aucun (ou déjà présent)"
        else
            echo "Swap              : ${SWAP_SIZE_GB} Go"
        fi
        if [[ "$SERVER_ROLE" == "1" ]]; then
            echo "Dokploy           : http://${SERVER_IP}:3000"
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
        local step_n=1
        echo "${step_n}. Vérifier la connexion SSH depuis un nouveau terminal :"
        echo "     ssh ${ADMIN_USER}@${SERVER_IP}"
        step_n=$((step_n+1))
        if [[ "$SERVER_ROLE" == "1" ]]; then
            echo ""
            echo "${step_n}. Pointer un nom de domaine vers ${SERVER_IP} (enregistrement DNS de type A)."
            step_n=$((step_n+1))
            echo ""
            echo "${step_n}. Dans Dokploy (http://${SERVER_IP}:3000), configurer le domaine et activer le TLS automatique."
            step_n=$((step_n+1))
            echo ""
            echo "${step_n}. Une fois le domaine actif, fermer manuellement l'accès direct au port 3000 :"
            if [[ -n "$DOKPLOY_RESTRICT_IP" ]]; then
                echo "     ufw delete allow from ${DOKPLOY_RESTRICT_IP} to any port 3000 proto tcp"
            else
                echo "     ufw delete allow 3000/tcp"
            fi
            step_n=$((step_n+1))
            echo ""
            echo "${step_n}. Désactiver l'accès direct via ip:port dans les réglages Dokploy."
            step_n=$((step_n+1))
        else
            echo ""
            echo "${step_n}. Ajouter ce serveur depuis le manager Dokploy : Settings → Servers → Add Server"
            echo "     IP : ${SERVER_IP} · Port SSH : ${SSH_PORT} · Utilisateur : ${ADMIN_USER}"
            step_n=$((step_n+1))
        fi
        if [[ -f "$PASSWORD_FILE" ]]; then
            echo ""
            echo "${step_n}. Supprimer le fichier mot de passe une fois noté :"
            echo "     shred -u ${PASSWORD_FILE}"
            step_n=$((step_n+1))
        fi
        if reboot_is_pending; then
            echo ""
            echo "⚠ Un nouveau kernel a été installé : redémarrer le serveur pour le charger :"
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
    else
        collect_hostname
        collect_admin_user
        collect_ssh_keys
        collect_timezone
        collect_swap
        collect_server_role
        if [[ "$SERVER_ROLE" == "1" ]]; then
            collect_dokploy_restrict_ip
            collect_advertise_addr
        fi
        show_recap

        confirm "Lancer l'initialisation avec ces paramètres ?" "o" \
            || { log_warn "Annulé par l'utilisateur."; exit 0; }
    fi

    detect_server_ip

    # En mode mise à jour, on ne relance pas un apt dist-upgrade complet à
    # chaque fois (déjà couvert par unattended-upgrades / vps-helper update) —
    # le mode mise à jour est documenté comme une réapplication légère de la
    # config (MOTD, vps-helper, durcissement...), pas une maintenance système.
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
    if [[ "$SERVER_ROLE" == "1" ]]; then
        step_dokploy
        step_traefik_tuning
    else
        log_info "Rôle 'remote server' : Dokploy ne sera pas installé ici, il sera ajouté depuis le manager central."
        ensure_docker
    fi
    step_save_state

    print_summary
    offer_password_cleanup

    log_ok "Initialisation terminée !"
}

main "$@"
