#!/usr/bin/env bash
#
# ROS 2 step-ca Security Bootstrap
#
# Creates SROS2 enclaves for the running ROS 2 nodes, gets their identity certificates
# from a step-ca, signs their permissions and installs automatic renewal
# (sros2_renew.sh + sros2-renew.service + sros2-renew.timer).
#
#   wget -qO- https://raw.githubusercontent.com/Michdo93/ros2-step-ca-security-bootstrap/main/setup_sros2.sh | bash
#   ./setup_sros2.sh --ca-url https://ca.lab:9000 --fingerprint <sha256> --provisioner admin@lab
#
# Requirements: ROS 2 (Humble or newer) with sros2, the step CLI, a reachable step-ca with
# a JWK provisioner, openssl. Run it as the user that runs the ROS 2 nodes (not as root):
# sudo is only used for the renewal script and the systemd units.
#
# Re-runnable: existing enclaves are skipped, new nodes get new enclaves.

set -o pipefail

usage() {
    cat <<'EOF'
Usage: setup_sros2.sh [options]

step-ca:
  --ca-url URL              step-ca URL, e.g. https://ca.lab:9000
  --fingerprint FP          SHA-256 fingerprint of the root certificate
  --root FILE               use this root certificate (verified against --fingerprint)
  --provisioner NAME        JWK provisioner, e.g. admin@lab
  --password-file FILE      file with the provisioner password (otherwise asked once)
  --not-after DURATION      certificate lifetime, e.g. 720h (default: provisioner default)

Keystore and enclaves:
  --keystore DIR            keystore (default ~/ros2_keystore)
  --policy-dir DIR          generated policies (default ~/ros2_policies)
  --enclaves LIST           comma separated enclaves, e.g. /talker,/ns/listener
                            (default: the nodes that are running)
  --permissions MODE        graph (least privilege from the running nodes, default)
                            or permissive (everything allowed within the domain)
  --no-cli-enclave          do not create the /ros2cli enclave for the ros2 tools
  --permissions-ca-cert F   shared permissions CA certificate (multi-host setups)
  --permissions-ca-key F    shared permissions CA private key
  --refresh-permissions     re-create the permissions of existing enclaves too
  --reissue                 request new certificates for existing enclaves too

Other:
  --no-bashrc               do not add the ROS_SECURITY_* exports to ~/.bashrc
  --no-timer                do not install sros2_renew.sh / systemd units
  --yes                     no questions (needs all required options)
  -h, --help                this help
EOF
}

main() {
    if [ -t 1 ]; then RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
    else RED=''; GREEN=''; YELLOW=''; NC=''; fi

    CA_URL="${STEP_CA_URL:-}"; FINGERPRINT="${STEP_FINGERPRINT:-}"; ROOT_IN=""; PROVISIONER="${STEP_PROVISIONER:-}"
    PASSWORD_FILE=""; NOT_AFTER=""
    KEYSTORE="${ROS_SECURITY_KEYSTORE:-$HOME/ros2_keystore}"; POLICY_DIR="$HOME/ros2_policies"
    ENCLAVES_ARG=""; PERM_MODE=graph; CLI_ENCLAVE=1; PERM_CA_CERT=""; PERM_CA_KEY=""
    REFRESH=0; REISSUE=0; BASHRC=1; TIMER=1; ASSUME_YES=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --ca-url) CA_URL=$2; shift 2 ;;
            --fingerprint) FINGERPRINT=$2; shift 2 ;;
            --root) ROOT_IN=$2; shift 2 ;;
            --provisioner) PROVISIONER=$2; shift 2 ;;
            --password-file) PASSWORD_FILE=$2; shift 2 ;;
            --not-after) NOT_AFTER=$2; shift 2 ;;
            --keystore) KEYSTORE=$2; shift 2 ;;
            --policy-dir) POLICY_DIR=$2; shift 2 ;;
            --enclaves) ENCLAVES_ARG=$2; shift 2 ;;
            --permissions) PERM_MODE=$2; shift 2 ;;
            --no-cli-enclave) CLI_ENCLAVE=0; shift ;;
            --permissions-ca-cert) PERM_CA_CERT=$2; shift 2 ;;
            --permissions-ca-key) PERM_CA_KEY=$2; shift 2 ;;
            --refresh-permissions) REFRESH=1; shift ;;
            --reissue) REISSUE=1; shift ;;
            --no-bashrc) BASHRC=0; shift ;;
            --no-timer) TIMER=0; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) error "Unknown option: $1 (see --help)" ;;
        esac
    done
    interactive=0
    if have_tty && [ "$ASSUME_YES" != 1 ]; then interactive=1; fi
    case "$PERM_MODE" in graph|permissive) ;; *) error "--permissions must be graph or permissive." ;; esac
    KEYSTORE=$(expand "$KEYSTORE"); POLICY_DIR=$(expand "$POLICY_DIR")
    RUN_USER="${USER:-$(id -un)}"

    # ---------- preconditions ----------
    if [ "$(id -u)" -eq 0 ]; then
        [ -n "${SUDO_USER:-}" ] && error "Do not run this script with sudo - run it as $SUDO_USER (sudo is used where needed)."
        warn "Running as root: the keystore lives in $HOME and the nodes must run as root, too."
        SUDO=""
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        SUDO=""; [ "$TIMER" = 1 ] && { warn "sudo is not available - the renewal timer cannot be installed."; TIMER=0; }
    fi
    command -v step >/dev/null 2>&1 || error "The step CLI is missing (install it with https://github.com/Michdo93/step-cli-bootstrap)."
    command -v openssl >/dev/null 2>&1 || error "openssl is missing (sudo apt-get install openssl)."
    load_ros
    ros2 security -h >/dev/null 2>&1 || error "'ros2 security' is not available - install sros2 (sudo apt install ros-$ROS_DISTRO-sros2)."
    command -v python3 >/dev/null 2>&1 || error "python3 is missing."
    info "ROS 2 $ROS_DISTRO, RMW ${RMW_IMPLEMENTATION:-default}, domain ${ROS_DOMAIN_ID:-0}, user $RUN_USER"

    # ---------- step-ca parameters ----------
    [ -n "$CA_URL" ] || CA_URL=$(ask_required "step-ca URL (e.g. https://ca.lab:9000): ")
    case "$CA_URL" in https://*) ;; *) error "The CA URL must start with https://" ;; esac
    if [ -z "$FINGERPRINT" ] && [ -z "$ROOT_IN" ]; then
        FINGERPRINT=$(ask_required "Root certificate fingerprint (step certificate fingerprint root_ca.crt): ")
    fi
    [ -n "$PROVISIONER" ] || PROVISIONER=$(ask_required "JWK provisioner name (step ca provisioner list): ")

    mkdir -p "$KEYSTORE" "$POLICY_DIR" || error "Cannot create $KEYSTORE / $POLICY_DIR."
    ROOT="$KEYSTORE/step_root_ca.crt"
    fetch_root
    check_provisioner
    WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
    get_password

    # ---------- keystore ----------
    if [ ! -d "$KEYSTORE/enclaves" ]; then
        info "Creating keystore $KEYSTORE ..."
        ros2 security create_keystore "$KEYSTORE" >/dev/null || error "ros2 security create_keystore failed."
    fi
    chmod 700 "$KEYSTORE/private"; chmod 600 "$KEYSTORE"/private/*.pem 2>/dev/null || true
    [ -n "$PERM_CA_CERT$PERM_CA_KEY" ] && import_permissions_ca

    # ---------- enclaves ----------
    discover_enclaves
    created=(); skipped=(); failed=()
    for enclave in "${ENCLAVES[@]}"; do
        handle_enclave "$enclave"
    done
    if [ "$CLI_ENCLAVE" = 1 ]; then
        PERM_SAVE=$PERM_MODE; PERM_MODE=permissive; handle_enclave /ros2cli; PERM_MODE=$PERM_SAVE
    fi
    update_identity_ca

    # ---------- environment (last: new shells start enforcing security from now on) ----------
    [ "$BASHRC" = 1 ] && write_bashrc

    # ---------- renewal ----------
    [ "$TIMER" = 1 ] && install_renewal

    # ---------- summary ----------
    printf '\n'
    info "Created: ${#created[@]}${created:+ (${created[*]})}"
    info "Skipped (already present): ${#skipped[@]}${skipped:+ (${skipped[*]})}"
    if [ "${#failed[@]}" -gt 0 ]; then warn "Failed: ${failed[*]}"; fi
    printf '\nStart every node with its own enclave, e.g. in a launch file:\n'
    for e in "${created[@]}" "${skipped[@]}"; do
        [ "$e" = /ros2cli ] && continue
        printf "    Node(..., name='%s', arguments=['--ros-args', '--enclave', '%s'])\n" "${e##*/}" "$e"
    done
    printf "or: ros2 run <pkg> <exe> --ros-args --enclave /<enclave>\n"
    [ "$CLI_ENCLAVE" = 1 ] && printf "ros2 tools: ROS_SECURITY_ENCLAVE_OVERRIDE=/ros2cli ros2 topic list --no-daemon\n"
    [ "$BASHRC" = 1 ] && printf 'Open a new shell (or: source ~/.bashrc) to activate ROS_SECURITY_ENABLE/STRATEGY/KEYSTORE.\n'
    [ "${#failed[@]}" -eq 0 ] || exit 1
}

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; exit 1; }
have_tty() { (exec </dev/tty) 2>/dev/null; }
# shellcheck disable=SC2088
expand() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }

ask() {  # prompt default
    local reply
    printf '%s' "$1" >/dev/tty
    IFS= read -r reply </dev/tty || reply=""
    printf '%s' "${reply:-$2}"
}
ask_required() {
    local v
    [ "$interactive" = 1 ] || error "Missing value: ${1%%(*} (no terminal - pass it as option)."
    while :; do v=$(ask "$1" ""); [ -n "$v" ] && { printf '%s' "$v"; return; }; done
}
ask_yes_no() {  # prompt default(yes|no)
    local a
    while :; do
        a=$(ask "$1" "$2")
        case "$a" in y|Y|yes|Yes|YES) printf yes; return ;; n|N|no|No|NO) printf no; return ;; esac
        printf "${YELLOW}[WARN]${NC} Please answer yes, Yes, y or no, No, n.\n" >/dev/tty
    done
}

# ROS 2 environment: already sourced, ROS_DISTRO set, or the only/newest /opt/ros/<distro>.
load_ros() {
    if ! command -v ros2 >/dev/null 2>&1; then
        local setup=""
        if [ -n "${ROS_DISTRO:-}" ] && [ -f "/opt/ros/$ROS_DISTRO/setup.bash" ]; then setup="/opt/ros/$ROS_DISTRO/setup.bash"
        else setup=$(ls -d /opt/ros/*/setup.bash 2>/dev/null | sort | tail -n 1); fi
        [ -n "$setup" ] || error "ROS 2 not found (no ros2 in PATH and no /opt/ros/<distro>/setup.bash)."
        # shellcheck disable=SC1090
        source "$setup"
    fi
    command -v ros2 >/dev/null 2>&1 || error "ros2 not found after sourcing the ROS 2 setup."
    ROS_DISTRO="${ROS_DISTRO:-unknown}"
}

fetch_root() {
    if [ -n "$ROOT_IN" ]; then
        [ -r "$ROOT_IN" ] || error "Cannot read $ROOT_IN."
        cp "$ROOT_IN" "$ROOT"
    else
        step ca root "$ROOT" --ca-url "$CA_URL" --fingerprint "$FINGERPRINT" --force >/dev/null ||
            error "Cannot get the root certificate from $CA_URL (URL, fingerprint, NO_PROXY?)."
    fi
    if [ -n "$FINGERPRINT" ]; then
        local fp want
        fp=$(step certificate fingerprint "$ROOT"); want=$(printf '%s' "$FINGERPRINT" | tr -d ' :' | tr 'A-F' 'a-f')
        [ "$fp" = "$want" ] || error "Fingerprint mismatch: root certificate has $fp."
    else
        FINGERPRINT=$(step certificate fingerprint "$ROOT")
    fi
    info "Root certificate: $ROOT (fingerprint ${FINGERPRINT:0:16}...)"
}

check_provisioner() {
    local type
    type=$(step ca provisioner list --ca-url "$CA_URL" --root "$ROOT" 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
for p in json.load(sys.stdin):
    if p.get("name") == name:
        print(p.get("type", "")); break' "$PROVISIONER")
    [ -n "$type" ] || error "Provisioner '$PROVISIONER' not found (list them: step ca provisioner list --ca-url $CA_URL --root $ROOT)."
    [ "$type" = JWK ] || error "Provisioner '$PROVISIONER' is of type $type; this script needs a JWK provisioner."
    info "Provisioner: $PROVISIONER (JWK)"
}

get_password() {
    PWFILE="$WORK/provisioner.pw"
    if [ -n "$PASSWORD_FILE" ]; then
        [ -r "$PASSWORD_FILE" ] || error "Cannot read $PASSWORD_FILE."
        cp "$PASSWORD_FILE" "$PWFILE"
    else
        [ "$interactive" = 1 ] || error "No terminal: pass the provisioner password with --password-file."
        local pw
        printf 'Password of provisioner %s: ' "$PROVISIONER" >/dev/tty
        stty -echo </dev/tty 2>/dev/null; IFS= read -r pw </dev/tty; stty echo </dev/tty 2>/dev/null; printf '\n' >/dev/tty
        (umask 077; printf '%s' "$pw" > "$PWFILE")
    fi
    chmod 600 "$PWFILE"
    # check the password once instead of failing for every enclave
    step ca token sros2-password-check --ca-url "$CA_URL" --root "$ROOT" --provisioner "$PROVISIONER" \
        --password-file "$PWFILE" >/dev/null 2>&1 || error "The provisioner password is wrong (or the CA is unreachable)."
}

write_bashrc() {
    local rc="$HOME/.bashrc" begin="# >>> ros2-step-ca-security-bootstrap >>>" end="# <<< ros2-step-ca-security-bootstrap <<<"
    touch "$rc"
    sed -i "/^$begin\$/,/^$end\$/d" "$rc"
    {
        printf '%s\n' "$begin"
        printf 'export ROS_SECURITY_KEYSTORE="%s"\n' "$KEYSTORE"
        printf 'export ROS_SECURITY_ENABLE=true\nexport ROS_SECURITY_STRATEGY=Enforce\n'
        printf '%s\n' "$end"
    } >> "$rc"
    info "ROS_SECURITY_KEYSTORE/ENABLE/STRATEGY added to $rc"
}

import_permissions_ca() {
    [ -r "$PERM_CA_CERT" ] && [ -r "$PERM_CA_KEY" ] || error "--permissions-ca-cert and --permissions-ca-key are both required and must be readable."
    [ "$(openssl x509 -noout -pubkey -in "$PERM_CA_CERT" | openssl sha256)" = "$(openssl pkey -pubout -in "$PERM_CA_KEY" | openssl sha256)" ] ||
        error "The permissions CA certificate and key do not belong together."
    if cmp -s "$PERM_CA_CERT" "$KEYSTORE/public/permissions_ca.cert.pem"; then
        info "Shared permissions CA is already in use."
        return
    fi
    info "Importing the shared permissions CA..."
    rm -f "$KEYSTORE/public/permissions_ca.cert.pem" "$KEYSTORE/private/permissions_ca.key.pem"
    install -m 644 "$PERM_CA_CERT" "$KEYSTORE/public/permissions_ca.cert.pem"
    install -m 600 "$PERM_CA_KEY" "$KEYSTORE/private/permissions_ca.key.pem"
    sign_smime "$KEYSTORE/enclaves/governance.xml" "$KEYSTORE/enclaves/governance.p7s" || error "Re-signing governance.xml failed."
    # the permissions of all existing enclaves must be signed by the new CA as well
    local p
    while read -r p; do
        sign_smime "$p" "${p%.xml}.p7s" || error "Re-signing $p failed."
    done < <(find "$KEYSTORE/enclaves" -mindepth 2 -name permissions.xml)
}

sign_smime() {  # xml p7s
    openssl smime -sign -text -in "$1" -out "$2.tmp" -signer "$KEYSTORE/public/permissions_ca.cert.pem" \
        -inkey "$KEYSTORE/private/permissions_ca.key.pem" -md sha256 2>/dev/null && mv "$2.tmp" "$2"
}

no_security() { env -u ROS_SECURITY_ENABLE -u ROS_SECURITY_STRATEGY -u ROS_SECURITY_KEYSTORE \
    -u ROS_SECURITY_ENCLAVE_OVERRIDE "$@"; }

discover_enclaves() {
    ENCLAVES=(); GRAPH_POLICY=""
    if [ -n "$ENCLAVES_ARG" ]; then
        IFS=',' read -r -a ENCLAVES <<< "${ENCLAVES_ARG// /}"
    else
        [ "$interactive" = 1 ] || error "No terminal: pass the enclaves with --enclaves /a,/b."
        printf '\nStart ALL ROS 2 nodes of this host now, WITHOUT security, in another terminal:\n'
        printf '    ROS_SECURITY_ENABLE=false ros2 launch <pkg> <file>.launch.py\n'
        printf 'Nodes that already have an enclave may keep running.\n'
        ask "Press Enter when all nodes are running... " "" >/dev/null
        local list="" try
        info "Discovering nodes..."
        for try in 1 2 3 4; do
            # discovery is timing dependent: merge several passes, stop after two with results
            list=$( { printf '%s\n' "$list"; no_security ros2 node list --no-daemon --spin-time 4 2>/dev/null; } |
                sed 's/\r$//' | grep '^/' | grep -v '^/_' | sort -u)
            [ -n "$list" ] && [ "$try" -ge 2 ] && break
        done
        [ -n "$list" ] || error "No running nodes found (same ROS_DOMAIN_ID? started without security?)."
        mapfile -t ENCLAVES <<< "$list"
        printf 'Running nodes (the whole ROS domain - nodes of other hosts are visible, too):\n'
        printf '    %s\n' "${ENCLAVES[@]}"
        if [ "$(ask_yes_no "Do ALL these nodes run on THIS host? (no: choose per node) (yes/no) [Default: yes]: " yes)" = no ]; then
            local chosen=() n
            for n in "${ENCLAVES[@]}"; do
                [ "$(ask_yes_no "  Enclave for $n on this host? (yes/no) [Default: yes]: " yes)" = yes ] && chosen+=("$n")
            done
            ENCLAVES=("${chosen[@]}")
            [ "${#ENCLAVES[@]}" -gt 0 ] || error "No node selected."
        fi
        [ "$PERM_MODE" = graph ] && generate_graph_policy
    fi
    local e
    for e in "${ENCLAVES[@]}"; do
        [[ "$e" =~ ^(/[A-Za-z_][A-Za-z0-9_]*)+$ ]] || error "Invalid enclave name '$e' (e.g. /talker or /ns/node)."
    done
}

# Policy of the running graph. generate_policy only sees what was discovered in time, so it
# is repeated until every selected node has a profile (max. 4 passes, results merged).
generate_graph_policy() {
    local try missing
    GRAPH_POLICY="$POLICY_DIR/graph-$(date +%Y%m%d-%H%M%S).policy.xml"
    info "Generating a policy from the running graph ($GRAPH_POLICY)..."
    for try in 1 2 3 4; do
        no_security ros2 security generate_policy --no-daemon "$WORK/pass.xml" >/dev/null 2>"$WORK/err" || continue
        missing=$(python3 - "$WORK/pass.xml" "$GRAPH_POLICY" "${ENCLAVES[@]}" <<'PY'
import os, sys, xml.etree.ElementTree as ET
new, merged, *nodes = sys.argv[1:]
base = ET.parse(merged) if os.path.exists(merged) else ET.parse(new)
broot = base.getroot()
profiles = broot.find("./enclaves/enclave/profiles")
have = {(p.get("ns"), p.get("node")) for p in profiles.iter("profile")}
for p in ET.parse(new).getroot().iter("profile"):
    key = (p.get("ns"), p.get("node"))
    if key not in have:
        profiles.append(p); have.add(key)
base.write(merged, xml_declaration=True, encoding="UTF-8")
for n in nodes:
    ns, _, name = n.rpartition("/")
    if (ns or "/", name) not in have:
        print(n)
PY
)
        [ -z "$missing" ] && return 0
        sleep 2
    done
    if [ ! -s "$GRAPH_POLICY" ]; then
        warn "generate_policy failed ($(tail -n 1 "$WORK/err")) - using permissive permissions."; GRAPH_POLICY=""
    else
        warn "No profile discovered for: $(echo $missing) - these get permissive permissions."
    fi
}

# Per-enclave policy from the graph policy (profile of node <ns, name>).
enclave_policy() {  # enclave out
    [ -n "$GRAPH_POLICY" ] && [ -s "$GRAPH_POLICY" ] || return 1
    python3 - "$GRAPH_POLICY" "$1" "$2" <<'PY'
import sys, xml.etree.ElementTree as ET
src, enclave, out = sys.argv[1:]
ns, _, node = enclave.rpartition("/")
ns = ns or "/"
root = ET.parse(src).getroot()
prof = next((p for p in root.iter("profile") if p.get("ns") == ns and p.get("node") == node), None)
if prof is None:
    sys.exit(3)
pol = ET.Element("policy", version=root.get("version", "0.2.0"))
enc = ET.SubElement(ET.SubElement(pol, "enclaves"), "enclave", path=enclave)
ET.SubElement(enc, "profiles").append(prof)
ET.ElementTree(pol).write(out, xml_declaration=True, encoding="UTF-8")
PY
}

issue_cert() {  # enclave dir
    local token args=()
    [ -n "$NOT_AFTER" ] && args=(--not-after "$NOT_AFTER")
    token=$(step ca token "$1" --ca-url "$CA_URL" --root "$ROOT" --provisioner "$PROVISIONER" \
        --password-file "$PWFILE" 2>"$WORK/err") || { warn "$(tail -n 1 "$WORK/err")"; return 1; }
    step ca certificate --token "$token" --ca-url "$CA_URL" --root "$ROOT" --force "${args[@]}" \
        "$1" "$2/cert.pem.new" "$2/key.pem.new" >/dev/null 2>"$WORK/err" || { warn "$(tail -n 1 "$WORK/err")"; return 1; }
    mv "$2/cert.pem.new" "$2/cert.pem"; mv "$2/key.pem.new" "$2/key.pem"; chmod 600 "$2/key.pem"
}

from_step_ca() {  # cert -> true if signed by the step-ca (chain to our root)
    [ -s "$1" ] && openssl verify -CAfile "$ROOT" -untrusted "$1" "$1" >/dev/null 2>&1
}

handle_enclave() {  # enclave
    local e=$1 dir="$KEYSTORE/enclaves$1" new=0 policy
    if [ -d "$dir" ] && from_step_ca "$dir/cert.pem" && [ "$REISSUE" != 1 ] && [ "$REFRESH" != 1 ]; then
        info "Enclave $e exists - skipped."; skipped+=("$e"); return
    fi
    if [ ! -d "$dir" ]; then
        ros2 security create_enclave "$KEYSTORE" "$e" >/dev/null 2>"$WORK/err" ||
            { warn "create_enclave $e failed: $(tail -n 1 "$WORK/err")"; failed+=("$e"); return; }
        new=1
    fi
    if [ "$new" = 1 ] || [ "$REISSUE" = 1 ] || ! from_step_ca "$dir/cert.pem"; then
        info "Enclave $e: requesting certificate from step-ca..."
        issue_cert "$e" "$dir" || { warn "Certificate for $e failed."; failed+=("$e"); [ "$new" = 1 ] && rm -rf "$dir"; return; }
    fi
    if [ "$new" = 1 ] || [ "$REFRESH" = 1 ]; then
        policy="$POLICY_DIR/${e#/}.policy.xml"; mkdir -p "$(dirname "$policy")"
        if [ "$PERM_MODE" = graph ] && enclave_policy "$e" "$policy"; then
            ros2 security create_permission "$KEYSTORE" "$e" "$policy" >/dev/null 2>"$WORK/err" ||
                { warn "create_permission $e failed: $(tail -n 1 "$WORK/err")"; failed+=("$e"); return; }
            info "Enclave $e: permissions from $policy"
        else
            [ "$PERM_MODE" = graph ] && warn "No graph profile for $e - permissive permissions (re-run with the node running for least privilege)."
            # create_enclave already wrote permissive permissions; re-sign them (CA may have changed)
            sign_smime "$dir/permissions.xml" "$dir/permissions.p7s" || { warn "Signing permissions of $e failed."; failed+=("$e"); return; }
        fi
    fi
    if [ "$new" = 1 ]; then created+=("$e"); else skipped+=("$e"); fi
}

# identity CA = intermediate(s) of the step-ca + root, so Fast DDS can verify the chain
update_identity_ca() {
    local cert target="$KEYSTORE/public/identity_ca.cert.pem"
    cert=$(find "$KEYSTORE/enclaves" -name cert.pem 2>/dev/null | while read -r c; do from_step_ca "$c" && { echo "$c"; break; }; done)
    [ -n "$cert" ] || return 0
    awk '/BEGIN CERTIFICATE/{n++} n>=2' "$cert" > "$WORK/chain.pem"
    cat "$ROOT" >> "$WORK/chain.pem"
    if ! cmp -s "$WORK/chain.pem" "$target"; then
        rm -f "$target"; install -m 644 "$WORK/chain.pem" "$target"
        info "Identity CA set to the step-ca chain ($target)."
    fi
}

install_renewal() {
    local list=() d e
    while read -r d; do
        e=${d#"$KEYSTORE/enclaves"}; from_step_ca "$d/cert.pem" && list+=("$e")
    done < <(find "$KEYSTORE/enclaves" -name cert.pem -printf '%h\n' | sort)
    [ "${#list[@]}" -gt 0 ] || return 0
    local stepbin; stepbin=$(command -v step)
    info "Installing /usr/local/bin/sros2_renew.sh (${#list[@]} enclaves)..."
    {
        printf '#!/bin/sh\n# Generated by ros2-step-ca-security-bootstrap - renews the SROS2 enclave certificates.\n'
        printf 'KEYSTORE="%s"\nCA_URL="%s"\nROOT="%s"\nSTEP="%s"\n' "$KEYSTORE" "$CA_URL" "$ROOT" "$stepbin"
        printf 'ENCLAVES="%s"\n' "${list[*]}"
        cat <<'EOF'
rc=0
for e in $ENCLAVES; do
    dir="$KEYSTORE/enclaves$e"
    [ -f "$dir/cert.pem" ] || { echo "$e: cert.pem missing"; rc=1; continue; }
    # renew after 2/3 of the lifetime
    if "$STEP" certificate needs-renewal "$dir/cert.pem" >/dev/null 2>&1; then
        if "$STEP" ca renew --force --ca-url "$CA_URL" --root "$ROOT" "$dir/cert.pem" "$dir/key.pem"; then
            echo "$e: renewed"
        else
            echo "$e: renewal FAILED (expired? then re-run setup_sros2.sh --reissue)"; rc=1
        fi
    else
        echo "$e: still valid"
    fi
done
exit $rc
EOF
    } > "$WORK/sros2_renew.sh"
    $SUDO install -m 755 "$WORK/sros2_renew.sh" /usr/local/bin/sros2_renew.sh

    if [ ! -d /run/systemd/system ]; then
        warn "systemd is not running - no timer installed. Run /usr/local/bin/sros2_renew.sh hourly (e.g. cron)."
        return
    fi
    cat > "$WORK/sros2-renew.service" <<EOF
[Unit]
Description=Renew SROS2 enclave certificates from step-ca
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$RUN_USER
ExecStart=/usr/local/bin/sros2_renew.sh
EOF
    cat > "$WORK/sros2-renew.timer" <<'EOF'
[Unit]
Description=Check the SROS2 enclave certificates hourly

[Timer]
OnBootSec=5min
OnCalendar=hourly
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    $SUDO install -m 644 "$WORK/sros2-renew.service" /etc/systemd/system/sros2-renew.service
    $SUDO install -m 644 "$WORK/sros2-renew.timer" /etc/systemd/system/sros2-renew.timer
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now sros2-renew.timer >/dev/null 2>&1 || warn "Enabling sros2-renew.timer failed."
    info "sros2-renew.service (User=$RUN_USER) and sros2-renew.timer installed and enabled."
}

main "$@"
