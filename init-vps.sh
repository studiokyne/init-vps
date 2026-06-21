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
# Le script pose toutes les questions nécessaires au fur et à mesure, avec
# une valeur par défaut entre crochets quand il y en a une (Entrée pour
# l'accepter). Chaque saisie est validée pour éviter les typos.
#
# Étapes :
#   0. Collecte interactive de la configuration + récapitulatif + confirmation
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
#  14. Commande d'aide vps-helper (whitelist, restart, logs, update...)
#  15. Limitation des logs Docker (rotation 10 Mo x 3 par conteneur)
#  16. Installation de Dokploy
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

# Variables collectées de façon interactive (valeurs par défaut ci-dessous)
SERVER_HOSTNAME=""
ADMIN_USER=""
SSH_PUBLIC_KEYS=()
TIMEZONE=""
SWAP_SIZE_GB=0
DOKPLOY_RESTRICT_IP=""
ADVERTISE_ADDR=""
WEBHOOK_URL=""
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
backup_file() {
    local f="$1"
    [[ -f "$f" ]] && cp -a "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)"
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

validate_url() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    # HTTPS uniquement (Discord/Slack n'utilisent que ça) — limite le risque
    # d'envoyer des infos de fin de script en clair sur le réseau.
    [[ "$v" =~ ^https://[^[:space:]]+$ ]]
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

collect_webhook() {
    log_step "Notification de fin de script (optionnel)"
    if confirm "Recevoir une notification (webhook Discord ou Slack) une fois le script terminé ?" "n"; then
        prompt WEBHOOK_URL "URL du webhook (https uniquement)" "" validate_url
    fi
}

collect_timezone() {
    log_step "Fuseau horaire"
    prompt TIMEZONE "Fuseau horaire (format Region/Ville)" "Europe/Paris" validate_timezone
}

show_recap() {
    log_step "Récapitulatif avant exécution"
    local swap_line dokploy_line advertise_line webhook_line
    [[ "$SWAP_SIZE_GB" -eq 0 ]] && swap_line="aucun" || swap_line="${SWAP_SIZE_GB} Go"
    [[ -n "$DOKPLOY_RESTRICT_IP" ]] && dokploy_line="restreint à ${DOKPLOY_RESTRICT_IP}" || dokploy_line="ouvert temporairement à tous"
    [[ -n "$ADVERTISE_ADDR" ]] && advertise_line="${ADVERTISE_ADDR}" || advertise_line="auto-détection (Dokploy)"
    [[ -n "$WEBHOOK_URL" ]] && webhook_line="activée" || webhook_line="désactivée"

    cat <<EOF
  Hostname                  : ${SERVER_HOSTNAME}
  Compte admin              : ${ADMIN_USER}
  Clé(s) SSH                : ${#SSH_PUBLIC_KEYS[@]} clé(s) fournie(s)
  Port SSH                  : ${SSH_PORT} (fixe)
  Fuseau horaire             : ${TIMEZONE}
  Swap                      : ${swap_line}
  Accès Dokploy (port 3000) : ${dokploy_line}
  Adresse Docker Swarm       : ${advertise_line}
  Notification webhook       : ${webhook_line}
EOF
    echo ""
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
        log_warn "L'utilisateur ${ADMIN_USER} existe déjà, création de compte ignorée (clés SSH mises à jour quand même)."
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
    backup_file "$authorized_keys"
    { [[ -f "$authorized_keys" ]] && cat "$authorized_keys"; printf '%s\n' "${SSH_PUBLIC_KEYS[@]}"; } \
        | awk 'NF && !seen[$0]++' > "${authorized_keys}.tmp"
    mv "${authorized_keys}.tmp" "$authorized_keys"
    chmod 600 "$authorized_keys"
    chown "${ADMIN_USER}:${ADMIN_USER}" "$authorized_keys"
    log_ok "${#SSH_PUBLIC_KEYS[@]} clé(s) SSH installée(s) pour ${ADMIN_USER}."
}

###############################################################################
# 4. FAIL2BAN — configuré et démarré AVANT l'ouverture SSH
###############################################################################
step_fail2ban() {
    log_step "Configuration de fail2ban"
    backup_file /etc/fail2ban/jail.local
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 4
backend  = systemd

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

    # Nettoyage des éventuelles anciennes règles sur le port 3000 (évite les
    # doublons/conflits si le script est relancé avec une restriction IP différente).
    local attempts=0 rule_num
    while ufw status numbered | grep -q '3000/tcp' && (( attempts < 10 )); do
        rule_num=$(ufw status numbered | grep '3000/tcp' | head -n1 | grep -oP '^\[\s*\K[0-9]+' || true)
        [[ -z "$rule_num" ]] && break
        yes | ufw delete "$rule_num" >/dev/null 2>&1 || true
        attempts=$((attempts+1))
    done

    if [[ -n "$DOKPLOY_RESTRICT_IP" ]]; then
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

# IMPORTANT : requis par le réseau Docker, ne pas désactiver
net.ipv4.ip_forward = 1
EOF
    sysctl --system >/dev/null
    log_ok "Durcissement réseau appliqué."
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
    if swapon --show | grep -q '/swapfile'; then
        log_warn "Un swapfile existe déjà, étape ignorée."
        return
    fi

    fallocate -l "${SWAP_SIZE_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB*1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
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

info() { echo -e "${C_DIM}[i]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[x]${C_RESET} $*" >&2; }

chk_pass() { printf '%b %s\n' "${C_GREEN}[PASS]${C_RESET}" "$1"; }
chk_fail() { printf '%b %s\n' "${C_RED}[FAIL]${C_RESET}" "$1"; }
chk_info() { printf '%b %s\n' "${C_CYAN}[INFO]${C_RESET}" "$1"; }
chk_sect() { printf '\n%b%s%b\n' "${C_DIM}── " "$1" " ────────────────────────────────────────${C_RESET}"; }

NEED_ROOT_CMDS="whitelist unban close-dokploy restart update check"
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
  ${C_CYAN}vps-helper restart <service>${C_RESET}   Redémarrer un service : ssh, fail2ban, docker
  ${C_CYAN}vps-helper logs <conteneur>${C_RESET}    Afficher les logs d'un conteneur Docker (Ctrl+C pour quitter)
  ${C_CYAN}vps-helper update${C_RESET}              Mettre à jour le système (sécurité incluse)
  ${C_CYAN}vps-helper check${C_RESET}               Vérifier l'état du durcissement (lecture seule)
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
    restart)        shift; cmd_restart "$@" ;;
    logs)           shift; cmd_logs "$@" ;;
    update)         cmd_update ;;
    check)          cmd_check ;;
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
step_dokploy() {
    log_step "Installation de Dokploy (Docker + Swarm inclus)"

    if command -v docker &>/dev/null && docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q '^active$'; then
        log_warn "Docker Swarm déjà actif sur ce serveur — Dokploy semble déjà installé, étape ignorée."
        usermod -aG docker "$ADMIN_USER" 2>/dev/null || true
        SERVER_IP=$(curl -s -4 --max-time 3 ifconfig.me || echo "${ADVERTISE_ADDR:-<IP_DU_SERVEUR>}")
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

    curl -fsSL https://dokploy.com/install.sh | sh

    usermod -aG docker "$ADMIN_USER"
    SERVER_IP=$(curl -s -4 --max-time 3 ifconfig.me || echo "${ADVERTISE_ADDR:-<IP_DU_SERVEUR>}")
    log_ok "Dokploy installé."
}

###############################################################################
# RÉSUMÉ FINAL
###############################################################################
print_summary() {
    # Calculé ici (et non en début de script) pour éviter tout décalage avec
    # le fuseau horaire défini en cours de route (step_system_misc).
    SUMMARY_FILE="/root/init-vps-summary-$(date +%Y%m%d-%H%M%S).txt"

    {
        echo "════════════════════════════════════════════════════"
        echo " RÉSUMÉ — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "════════════════════════════════════════════════════"
        echo "Version init-vps  : ${SCRIPT_VERSION}"
        echo "Hostname          : ${SERVER_HOSTNAME}"
        echo "Compte admin      : ${ADMIN_USER}"
        echo "Port SSH          : ${SSH_PORT}"
        echo "Clé(s) SSH        : ${#SSH_PUBLIC_KEYS[@]} installée(s)"
        if [[ "$SWAP_SIZE_GB" -eq 0 ]]; then
            echo "Swap              : aucun (ou déjà présent)"
        else
            echo "Swap              : ${SWAP_SIZE_GB} Go"
        fi
        echo "Dokploy           : http://${SERVER_IP}:3000"
        echo "Fichier log       : ${LOG_FILE}"
        [[ -f "$PASSWORD_FILE" ]] && echo "Mot de passe sudo : ${PASSWORD_FILE} (à supprimer une fois noté)"
        echo ""
        echo "PROCHAINES ÉTAPES"
        echo "──────────────────────────────────────────────────"
        echo "1. Vérifier la connexion SSH depuis un nouveau terminal :"
        echo "     ssh ${ADMIN_USER}@${SERVER_IP}"
        echo ""
        echo "2. Pointer un nom de domaine vers ${SERVER_IP} (enregistrement DNS de type A)."
        echo ""
        echo "3. Dans Dokploy (http://${SERVER_IP}:3000), configurer le domaine et activer le TLS automatique."
        echo ""
        echo "4. Une fois le domaine actif, fermer manuellement l'accès direct au port 3000 :"
        if [[ -n "$DOKPLOY_RESTRICT_IP" ]]; then
            echo "     ufw delete allow from ${DOKPLOY_RESTRICT_IP} to any port 3000 proto tcp"
        else
            echo "     ufw delete allow 3000/tcp"
        fi
        echo ""
        echo "5. Désactiver l'accès direct via ip:port dans les réglages Dokploy."
        if [[ -f "$PASSWORD_FILE" ]]; then
            echo ""
            echo "6. Supprimer le fichier mot de passe une fois noté :"
            echo "     shred -u ${PASSWORD_FILE}"
        fi
    } | tee "$SUMMARY_FILE" | tee -a "$LOG_FILE"

    echo ""
    log_ok "Résumé sauvegardé dans ${SUMMARY_FILE}"
}

notify_webhook() {
    [[ -z "$WEBHOOK_URL" ]] && return
    local payload msg
    msg="Initialisation terminee sur $(hostname) - Dokploy : http://${SERVER_IP}:3000"
    payload=$(printf '{"content":"%s","text":"%s"}' "$msg" "$msg")
    if curl -fsS -X POST -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1; then
        log_ok "Notification webhook envoyée."
    else
        log_warn "Échec de l'envoi de la notification webhook (vérifier l'URL)."
    fi
}

offer_password_cleanup() {
    [[ -f "$PASSWORD_FILE" ]] || return
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

    collect_hostname
    collect_admin_user
    collect_ssh_keys
    collect_timezone
    collect_swap
    collect_dokploy_restrict_ip
    collect_advertise_addr
    collect_webhook
    show_recap

    confirm "Lancer l'initialisation avec ces paramètres ?" "o" \
        || { log_warn "Annulé par l'utilisateur."; exit 0; }

    step_update_system
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
    step_dokploy

    print_summary
    notify_webhook
    offer_password_cleanup

    log_ok "Initialisation terminée !"
}

main "$@"
