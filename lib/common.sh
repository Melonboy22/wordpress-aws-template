#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# (SC2034 disabled for this file: the variables below are used by the scripts that source it)
# =============================================================================
# lib/common.sh - shared configuration + helper functions
#
# This file is SOURCED (not executed) by 01-, 02- and 99- scripts.
# Why a shared file?  The region, domain, project tag and resource names must
# be identical in all three scripts - otherwise script 2 could not find what
# script 1 created, and the teardown could miss something. Defining them in
# ONE place makes that impossible to get wrong.
#
# Written for bash 3.2 (the version macOS ships), so no mapfile / assoc arrays.
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ============================ SHARED CONFIGURATION ===========================
# YOUR settings live in config.env (git-ignored). Create it with:
#     cp config.example.env config.env      # then edit it
CONFIG_FILE="${PROJECT_DIR}/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  printf 'Missing %s\nCreate it first:  cp config.example.env config.env   (then edit it)\n' "$CONFIG_FILE" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

config_error() { printf 'config.env: %s\n' "$*" >&2; exit 1; }
[[ -n "${DOMAIN:-}" && "$DOMAIN" != "example.com" ]] || config_error "set DOMAIN to your own domain"
[[ -n "${WP_ADMIN_EMAIL:-}" && "$WP_ADMIN_EMAIL" != "you@example.com" ]] || config_error "set WP_ADMIN_EMAIL"
AWS_REGION="${AWS_REGION:-us-east-1}"   # every regional resource lives here
PROJECT="${PROJECT:-wordpress-site}"    # value of the Project=... tag on everything
[[ "$PROJECT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || config_error "PROJECT must be 3-31 chars: lowercase letters, digits, '-'"
WP_TITLE="${WP_TITLE:-My WordPress Site}"
WP_ADMIN_USER="${WP_ADMIN_USER:-siteadmin}"
WWW_DOMAIN="www.${DOMAIN}"
SSM_PREFIX="/${PROJECT}"                # Parameter Store namespace for secrets

# Resource names (derived from PROJECT so they are easy to recognise in the console)
INSTANCE_NAME="${PROJECT}-web"
WEB_SG_NAME="web-sg"
DB_SG_NAME="db-sg"
ROLE_NAME="${PROJECT}-ec2-role"
INSTANCE_PROFILE_NAME="${PROJECT}-ec2-profile"
KEY_NAME="${PROJECT}-key"
EIP_NAME="${PROJECT}-eip"
DB_INSTANCE_ID="${PROJECT}-db"
DB_SUBNET_GROUP="${PROJECT}-db-subnets"
WP_ADMIN_PW_PARAM="${SSM_PREFIX}/wp/admin-password"
SSM_DB_PREFIX="${SSM_PREFIX}/db"
# =============================================================================

STATE_FILE="${PROJECT_DIR}/state.env"            # IDs of created resources (git-ignored)
KEY_FILE="${PROJECT_DIR}/${KEY_NAME}.pem"        # SSH private key (git-ignored)

# Make every `aws` call use our region, and never open a pager (less) - a pager
# would freeze an unattended script waiting for a keypress.
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

# ------------------------------- Logging -------------------------------------
# Colours only when writing to a real terminal (keeps log files clean).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi
STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s==> Step %d: %s%s\n' "$C_BLUE" "$STEP_NO" "$*" "$C_RESET"; }
why()  { printf '%s    why: %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s    [ok] %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s    [warn] %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die()  { printf '%s    [error] %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# If any command fails (set -e), say WHERE before exiting, instead of dying silently.
trap 'printf "%s    [error] command failed (exit %s) at line %s: %s%s\n" "$C_RED" "$?" "$LINENO" "$BASH_COMMAND" "$C_RESET" >&2' ERR

# ------------------------------- State file ----------------------------------
# state.env is a simple KEY=value file. It lets script 2 and the teardown know
# which IDs script 1 created, and documents the deployment for the report.
# The scripts never TRUST it blindly - they still look resources up by tag/name.
state_set() {
  local key="$1" value="$2" tmp
  touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$STATE_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$STATE_FILE"; chmod 600 "$STATE_FILE"
}
state_get() {
  [[ -f "$STATE_FILE" ]] || return 0
  grep "^$1=" "$STATE_FILE" | tail -n 1 | cut -d= -f2- || true
}

# ------------------------------- AWS helpers ---------------------------------
# `aws ... --output text` prints the literal word "None" for a missing value.
# aws_text turns that into an empty string so we can test with [[ -z ... ]].
aws_text() {
  local out
  out="$(aws "$@" --output text)" || return $?   # propagate AWS errors to the caller
  [[ "$out" == "None" ]] && out=""
  printf '%s' "$out"
}

# Tag specification used at CREATE time. Tagging at creation (instead of
# afterwards) means a resource is never untagged, so idempotency lookups and the
# teardown can always find it.
tag_spec() { # $1 = EC2 resource type, $2 = Name tag
  printf 'ResourceType=%s,Tags=[{Key=Project,Value=%s},{Key=Name,Value=%s}]' "$1" "$PROJECT" "$2"
}

preflight() {
  command -v aws >/dev/null 2>&1 || die "AWS CLI v2 not found. Install it: brew install awscli"
  local arn
  arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)" \
    || die "AWS credentials are not working. Run 'aws login' (or 'aws configure') first."
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  info "Account: ${ACCOUNT_ID}   Identity: ${arn}   Region: ${AWS_REGION}"
  if [[ "$arn" == *":root" ]]; then
    warn "You are signed in as the account ROOT user. It works, but best practice is an IAM user/role with admin rights."
  fi
}

default_vpc_id() {
  aws_text ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId'
}

# Returns the public hosted zone ID (without the /hostedzone/ prefix), or "".
lookup_hosted_zone() {
  local id
  id="$(aws_text route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
        --query "HostedZones[?Name=='${DOMAIN}.' && Config.PrivateZone==\`false\`] | [0].Id")"
  printf '%s' "${id#/hostedzone/}"
}

# Newest non-terminated instance carrying our Project + Name tags.
find_instance_id() {
  aws_text ec2 describe-instances \
    --filters "Name=tag:Project,Values=${PROJECT}" "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'sort_by(Reservations[].Instances[], &LaunchTime) | [-1].InstanceId'
}

find_sg_id() { # $1 = group name, $2 = VPC id
  aws_text ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$2" \
    --query 'SecurityGroups[0].GroupId'
}

# Add an inbound rule from a CIDR. AWS rejects exact duplicates with
# InvalidPermission.Duplicate - for us that simply means "already done".
sg_allow_cidr() { # $1 sg-id, $2 port, $3 cidr, $4 description
  local out perms
  perms="$(printf '[{"IpProtocol":"tcp","FromPort":%s,"ToPort":%s,"IpRanges":[{"CidrIp":"%s","Description":"%s"}]}]' "$2" "$2" "$3" "$4")"
  if out="$(aws ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "$perms" 2>&1)"; then
    ok "rule added:   tcp/$2 from $3 ($4)"
  elif grep -q 'InvalidPermission.Duplicate' <<<"$out"; then
    ok "rule exists:  tcp/$2 from $3"
  else
    die "$out"
  fi
}

# Add an inbound rule whose SOURCE is another security group (not an IP range).
sg_allow_sg() { # $1 sg-id, $2 port, $3 source sg-id, $4 description
  local out perms
  perms="$(printf '[{"IpProtocol":"tcp","FromPort":%s,"ToPort":%s,"UserIdGroupPairs":[{"GroupId":"%s","Description":"%s"}]}]' "$2" "$2" "$3" "$4")"
  if out="$(aws ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "$perms" 2>&1)"; then
    ok "rule added:   tcp/$2 from security group $3 ($4)"
  elif grep -q 'InvalidPermission.Duplicate' <<<"$out"; then
    ok "rule exists:  tcp/$2 from security group $3"
  else
    die "$out"
  fi
}

# ----------------------------- Secret helpers --------------------------------
random_secret() { openssl rand -hex 20; }   # 40 hex chars: strong, and no quoting problems in SQL/PHP/sed

param_exists() { aws ssm get-parameter --name "$1" --query Parameter.Name --output text >/dev/null 2>&1; }

# Store a SecureString WITHOUT the value ever appearing on a command line
# (command lines are visible in `ps` and shell history). The CLI's file://
# syntax reads the value from a private temp file instead.
put_secure_param() { # $1 name, $2 value, $3 description
  local tmp
  tmp="$(umask 077; mktemp)"
  printf '%s' "$2" > "$tmp"
  aws ssm put-parameter --name "$1" --type SecureString --value "file://${tmp}" \
    --description "$3" --tags "Key=Project,Value=${PROJECT}" >/dev/null
  rm -f "$tmp"
}

# Create a random SecureString only if it doesn't exist yet (idempotent).
# Sets SECRET_CREATED=true when a new value was generated.
ensure_random_secret() { # $1 name, $2 description
  SECRET_CREATED=false
  if param_exists "$1"; then
    ok "reusing existing SecureString $1"
  else
    put_secure_param "$1" "$(random_secret)" "$2"
    SECRET_CREATED=true
    ok "created SecureString $1 (value not shown)"
  fi
}

# Plain (non-secret) parameter; created with tags first time, overwritten later.
put_plain_param() { # $1 name, $2 value, $3 description, [$4 type]
  local type="${4:-String}" tmp
  if param_exists "$1"; then
    if [[ "$type" == "SecureString" ]]; then
      tmp="$(umask 077; mktemp)"; printf '%s' "$2" > "$tmp"
      aws ssm put-parameter --name "$1" --type "$type" --value "file://${tmp}" --overwrite >/dev/null
      rm -f "$tmp"
    else
      aws ssm put-parameter --name "$1" --type "$type" --value "$2" --overwrite >/dev/null
    fi
  elif [[ "$type" == "SecureString" ]]; then
    put_secure_param "$1" "$2" "$3"
  else
    aws ssm put-parameter --name "$1" --type "$type" --value "$2" \
      --description "$3" --tags "Key=Project,Value=${PROJECT}" >/dev/null
  fi
}

# ---------------------------- SSM Run Command --------------------------------
# Wait until the SSM Agent on the instance has registered ("Online"). Until then
# Run Command cannot reach it.
wait_ssm_online() { # $1 instance-id, $2 timeout seconds
  local deadline=$((SECONDS + $2)) status
  while :; do
    status="$(aws_text ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$1" --query 'InstanceInformationList[0].PingStatus' 2>/dev/null || true)"
    [[ "$status" == "Online" ]] && { ok "SSM Agent on $1 is Online"; return 0; }
    (( SECONDS > deadline )) && die "SSM Agent on $1 did not come Online within $2 s (status: ${status:-not registered})."
    info "waiting for SSM Agent registration... (${status:-not registered yet})"
    sleep 10
  done
}

# Run a local script file on the instance as root through SSM Run Command.
#   run_remote_script <instance-id> <script-file> <comment> <timeout-s> [VAR=value ...]
# The script is base64-encoded so quotes/newlines survive the trip unchanged.
# VAR=value pairs become `export` lines at the top. ONLY non-secret values go
# there: Run Command parameters are stored in the SSM command history. Secrets
# are fetched by the remote script itself from Parameter Store.
# Sets REMOTE_STATUS and prints the remote stdout/stderr indented.
run_remote_script() {
  local instance_id="$1" script="$2" comment="$3" timeout="$4"; shift 4
  local remote_name payload json cmd_id deadline kv out err
  remote_name="/root/${PROJECT}-$(basename "$script")"
  payload="$( { for kv in "$@"; do printf 'export %q\n' "$kv"; done; cat "$script"; } | base64 | tr -d '\n')"
  json="$(mktemp)"
  printf '{"commands":["echo %s | base64 -d > %s","chmod 700 %s","bash %s"],"executionTimeout":["%s"]}' \
    "$payload" "$remote_name" "$remote_name" "$remote_name" "$timeout" > "$json"
  cmd_id="$(aws ssm send-command --instance-ids "$instance_id" --document-name AWS-RunShellScript \
              --comment "$comment" --parameters "file://${json}" --query Command.CommandId --output text)"
  rm -f "$json"
  info "SSM command ${cmd_id} sent; waiting for it to finish..."
  deadline=$((SECONDS + timeout + 60))
  while :; do
    REMOTE_STATUS="$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$instance_id" \
                       --query Status --output text 2>/dev/null || echo Pending)"
    case "$REMOTE_STATUS" in Pending|InProgress|Delayed) ;; *) break ;; esac
    (( SECONDS > deadline )) && die "SSM command ${cmd_id} did not finish in time."
    sleep 5
  done
  out="$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$instance_id" --query StandardOutputContent --output text)"
  err="$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$instance_id" --query StandardErrorContent --output text)"
  printf '%s\n' "$out" | sed "s/^/${C_DIM}    | ${C_RESET}/"
  if [[ "$REMOTE_STATUS" != "Success" && -n "$err" && "$err" != "None" ]]; then
    printf '%s\n' "$err" | tail -n 30 | sed "s/^/${C_YELLOW}    ! ${C_RESET}/"
  fi
  [[ "$REMOTE_STATUS" == "Success" ]]
}

# ------------------------------- HTTP check ----------------------------------
# Returns 0 when URL answers like WordPress: HTTP 200/301/302 AND the
# response mentions wp-content / wp-admin / wp-json (so the default Apache
# test page or an error page doesn't count as success).
#
# Optional 2nd argument = IP to pin the host name to (curl --resolve). The
# request is still exactly http(s)://<your-domain>/ (same Host header, same TLS
# name), but the connection goes straight to our Elastic IP. Why: the server
# check must not depend on DNS propagation, local DNS caches or the domain's
# registrar status - public DNS is verified separately by public_dns_ok.
wordpress_responds() { # $1 url, [$2 ip] ; sets HTTP_CODE
  local hdr body host
  local -a pin=()
  if [[ -n "${2:-}" ]]; then
    host="${1#*://}"; host="${host%%/*}"
    pin=(--resolve "${host}:80:$2" --resolve "${host}:443:$2")
  fi
  hdr="$(mktemp)"; body="$(mktemp)"
  # ${pin[@]+...} = expand only if set: bash 3.2 + `set -u` errors on an empty array.
  HTTP_CODE="$(curl -s -o "$body" -D "$hdr" -w '%{http_code}' --max-time 10 ${pin[@]+"${pin[@]}"} "$1" 2>/dev/null || true)"
  HTTP_CODE="${HTTP_CODE:-000}"
  if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]] && grep -qiE 'wp-content|wp-admin|wp-json' "$hdr" "$body"; then
    rm -f "$hdr" "$body"; return 0
  fi
  rm -f "$hdr" "$body"; return 1
}

# ------------------------------- DNS check -----------------------------------
# Does the PUBLIC internet resolve $1 to $2? Asks a public resolver (Google
# 8.8.8.8), not this Mac's cache, so the answer is what visitors see.
public_dns_ok() { # $1 name, $2 expected IP
  [[ "$(dig +short +time=3 +tries=2 A "$1" @8.8.8.8 2>/dev/null | tail -n 1)" == "$2" ]]
}

# When public DNS fails although Route 53 is correct, the usual cause is the
# domain REGISTRATION, not the hosted zone: e.g. "clientHold" = suspended by
# the registry because the registrant email was never verified (ICANN rule).
explain_dns_failure() {
  local status reach
  status="$(aws_text route53domains get-domain-detail --region us-east-1 --domain-name "$DOMAIN" --query 'StatusList' 2>/dev/null || true)"
  reach="$(aws_text route53domains get-contact-reachability-status --region us-east-1 --domain-name "$DOMAIN" --query status 2>/dev/null || true)"
  warn "Public DNS does not resolve ${DOMAIN} yet. Route 53 records are correct; the server was verified directly via its Elastic IP."
  [[ -n "$status" ]] && warn "Domain registration status: ${status}   registrant email verification: ${reach:-unknown}"
  if [[ "$status" == *clientHold* && "$reach" == "DONE" ]]; then
    warn "clientHold = the registry suspended the domain. The registrant email IS verified now, so AWS should lift the hold"
    warn "automatically (usually minutes to a few hours); DNS starts working right after. Nothing to change in AWS."
  elif [[ "$status" == *clientHold* ]]; then
    warn "clientHold = the registry suspended the domain, usually because the registrant email was not verified."
    warn "Fix: click the link in the AWS 'verify your email' message (resend: aws route53domains resend-contact-reachability-email --region us-east-1 --domain-name ${DOMAIN})."
  else
    warn "If the domain is new or its name servers just changed, propagation can take up to 48 h."
  fi
}
