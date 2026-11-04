#!/usr/bin/env bash
# WorldSkills Cloud Computing - grading script, Module B: Automation (Korea 2021 National - Task 2)
# Usage: bash grade_B.sh [--list] [--only IDS] [--yes] [-v|--show-cmds]      (default region: us-east-1)

# ============================================================================
#  Common helpers (embedded in every grading script)
# ============================================================================
set -o pipefail

export AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_REGION="$AWS_DEFAULT_REGION"
export AWS_PAGER=""

SSH_USER="${SSH_USER:-ec2-user}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
SSH_PASS="${SSH_PASS:-}"
REMOTE_MODE="${REMOTE_MODE:-auto}"   # auto (SSM when the instance is Online in SSM, else SSH) | ssm | ssh
SSM_TIMEOUT="${SSM_TIMEOUT:-90}"     # max seconds to wait for an SSM Run Command result

YES=0
ONLY=""
LIST=0
SHOW_CMDS="${SHOW_CMDS:-0}"   # 1 = print every command executed (--show-cmds / -v)
_SHOW_MUTE=0                   # set while polling, so loops print their commands only once
CMD_FILE=""
exec 3>&1                      # fd 3 = where the executed commands are printed
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-$PWD}"

if [ -t 1 ]; then
  C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_B=$'\e[1;34m'; C_D=$'\e[2m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
  C_G=""; C_R=""; C_Y=""; C_B=""; C_D=""; C_C=""; C_0=""
fi

CACHE_DIR="$(mktemp -d)"; trap 'rm -rf "$CACHE_DIR"' EXIT
# cached KEY command...  -> run once and reuse the value (also works inside $(...) subshells)
cached() {
  local k="$1" v; shift
  if [ -s "$CACHE_DIR/$k" ]; then cat "$CACHE_DIR/$k"; echo; return 0; fi
  v=$("$@"); [ -n "$v" ] && printf '%s' "$v" >"$CACHE_DIR/$k"
  printf '%s\n' "$v"
}

declare -a ASPECTS=() RES_ID=() RES_NAME=() RES_MAX=() RES_GOT=() RES_NOTE=()
NOTE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --only IDS     Run only these aspects (comma separated). A prefix selects a
                 whole sub-criterion, e.g. --only ${MODULE}1,${MODULE}4.2
  --list         List the aspects and their marks, then exit
  --yes          Do not ask before destructive steps (scaling, commits...)
  -v, --show-cmds
                 Show every command executed (aws, curl, ssh, docker...) under
                 each criterion, and save them to grade_<module>_<date>_commands.txt
  -h, --help     Show this help

Environment:
  AWS_REGION     AWS region (default: us-east-1)
  SSH_USER       SSH user for the competitor's instances (default: ec2-user)
  SSH_KEY        Private key for SSH (optional)
  SSH_PASS       SSH password (optional, needs sshpass installed)
  REMOTE_MODE    How commands run on the instances: auto (SSM Run Command when the
                 instance is Online in Systems Manager, else SSH), ssm or ssh (default: auto)
  SSM_TIMEOUT    Max seconds to wait for an SSM Run Command result (default: 90)
  OUT_DIR        Where the log and CSV are written (default: current dir)
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --only) ONLY="$2"; shift 2 ;;
      --only=*) ONLY="${1#*=}"; shift ;;
      --list) LIST=1; shift ;;
      --yes|-y) YES=1; shift ;;
      --show-cmds|-v) SHOW_CMDS=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
}

# aspect ID "Name" MAX function
aspect() { ASPECTS+=("$1|$2|$3|$4"); }

selected() {
  local id="$1" sel
  [ -z "$ONLY" ] && return 0
  IFS=',' read -r -a sel <<<"$ONLY"
  for s in "${sel[@]}"; do
    s="${s// /}"
    [ "$id" = "$s" ] && return 0
    case "$id" in "$s".*) return 0 ;; esac
  done
  return 1
}

section() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
info()  { printf '   %s%s%s\n' "$C_D" "$*" "$C_0"; }
ok()    { printf '   %s✔ %s%s\n' "$C_G" "$*" "$C_0"; }
bad()   { printf '   %s✘ %s%s\n' "$C_R" "$*" "$C_0"; NOTE="${NOTE:+$NOTE; }$*"; }
warn()  { printf '   %s! %s%s\n' "$C_Y" "$*" "$C_0"; }

# expect "description" actual expected  -> compares exactly
expect() {
  if [ "$2" = "$3" ]; then ok "$1: $2"; return 0; fi
  bad "$1: got '${2:-<empty>}', expected '$3'"; return 1
}

# expect_match "description" actual regex
expect_match() {
  if [[ "$2" =~ $3 ]]; then ok "$1: $2"; return 0; fi
  bad "$1: got '${2:-<empty>}', expected to match /$3/"; return 1
}

confirm() {
  [ "$YES" = 1 ] && return 0
  local a; read -r -p "   ${C_Y}?${C_0} $* [y/N] " a </dev/tty
  [[ "$a" =~ ^[yYsS] ]]
}

# Manual check: the grader answers y/n
manual() {
  local a; read -r -p "   ${C_Y}?${C_0} $* [y/N] " a </dev/tty
  if [[ "$a" =~ ^[yYsS] ]]; then ok "confirmed by grader"; return 0; fi
  bad "not confirmed by grader"; return 1
}

pause() { [ "$YES" = 1 ] && return 0; read -r -p "   ${C_Y}>${C_0} $* (press Enter) " _ </dev/tty; }

# wait_for TIMEOUT_SECONDS INTERVAL "description" command...
wait_for() {
  local timeout="$1" interval="$2" desc="$3"; shift 3
  local start mute="$_SHOW_MUTE" first=1; start=$(date +%s)
  printf '   %swaiting (max %ss): %s%s ' "$C_D" "$timeout" "$desc" "$C_0"
  [ "$SHOW_CMDS" = 1 ] && [ "$mute" = 0 ] && printf '%s(polling every %ss)%s\n' "$C_D" "$interval" "$C_0"
  while :; do
    if "$@" >/dev/null 2>&1; then _SHOW_MUTE=$mute; printf '%s(%ss)%s\n' "$C_D" "$(( $(date +%s) - start ))" "$C_0"; return 0; fi
    [ "$first" = 1 ] && { first=0; _SHOW_MUTE=1; [ "$SHOW_CMDS" = 1 ] && [ "$mute" = 0 ] && printf '   '; }
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then _SHOW_MUTE=$mute; printf '%stimeout%s\n' "$C_R" "$C_0"; return 1; fi
    printf '.'; sleep "$interval"
  done
}

# ---------------------------------------------------------------- command display (--show-cmds)
# Quote arguments only when needed, so the printed command can be copied and run again
shq() {
  local a out=""
  for a in "$@"; do
    if [[ "$a" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+="$a "
    elif [[ "$a" == *\'* && "$a" != *[\"\$\`\\!]* ]]; then out+="\"$a\" "
    else out+="'${a//\'/\'\\\'\'}' "; fi
  done
  printf '%s' "${out% }"
}
# Print a preformatted command line (long tokens such as ECR passwords are hidden)
show_raw() {
  [ "$SHOW_CMDS" = 1 ] && [ "$_SHOW_MUTE" = 0 ] || return 0
  local s; s=$(sed -E 's/[A-Za-z0-9+\/=]{200,}/<redacted>/g' <<<"$1")
  local line first=1
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then printf '   %s$ %s%s\n' "$C_C" "$line" "$C_0"; first=0
    else printf '   %s  %s%s\n' "$C_C" "$line" "$C_0"; fi
  done <<<"$s" >&3
  [ -n "$CMD_FILE" ] && printf '%s\n' "$s" >>"$CMD_FILE"
  return 0
}
show_cmd() { [ "$SHOW_CMDS" = 1 ] && [ "$_SHOW_MUTE" = 0 ] && show_raw "$(shq "$@")"; return 0; }

# Wrappers: every call to these commands is shown when --show-cmds is on
aws()     { show_cmd aws "$@";     command aws "$@"; }
curl()    { show_cmd curl "$@";    command curl "$@"; }
docker()  { show_cmd docker "$@";  command docker "$@"; }
sudo()    { show_cmd sudo "$@";    command sudo "$@"; }
timeout() { show_cmd timeout "$@"; command timeout "$@"; }
unzip()   { show_cmd unzip "$@";   command unzip "$@"; }

awsj() { aws "$@" --output json 2>/dev/null; }
awst() { aws "$@" --output text 2>/dev/null | tr '\t' '\n' | sed '/^None$/d;/^$/d'; }

need() {
  local bin="$1" pkg="${2:-$1}"
  command -v "$bin" >/dev/null 2>&1 && return 0
  warn "$bin not found - installing $pkg"
  sudo yum install -y "$pkg" >/dev/null 2>&1 || sudo dnf install -y "$pkg" >/dev/null 2>&1 || true
  command -v "$bin" >/dev/null 2>&1 || { echo "${C_R}Missing required command: $bin${C_0}" >&2; exit 1; }
}

# Safe matching against captured output (avoids SIGPIPE with pipefail)
has_line() { grep -qxF -- "$1" <<<"$2"; }
has_re()   { grep -qE -- "$1" <<<"$2"; }

aws_v2() { has_re '^aws-cli/2' "$(command aws --version 2>&1)"; }

ec2_id_by_ip() {   # id of the running instance with private IP $1
  awst ec2 describe-instances --filters "Name=private-ip-address,Values=$1" "Name=instance-state-name,Values=running" \
       --query "Reservations[].Instances[].InstanceId" | head -1
}
ssm_online() {     # true if instance $1 is registered in Systems Manager and Online
  [ "$(awst ssm describe-instance-information --filters "Key=InstanceIds,Values=$1" \
        --query "InstanceInformationList[].PingStatus")" = Online ]
}

# Run a command on instance $1 through SSM Run Command (AWS-RunShellScript, runs as root).
# Prints the command's stdout (its stderr goes to stderr) and returns its exit code.
rssm() {
  local id="$1"; shift
  local params cid j st rc start mute="$_SHOW_MUTE"
  params=$(jq -cn --arg c "$*" '{commands: ($c | split("\n"))}')
  cid=$(awst ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
          --parameters "$params" --query Command.CommandId)
  [ -z "$cid" ] && { echo "SSM: send-command failed on $id (is it Online in Systems Manager?)" >&2; return 1; }
  start=$(date +%s)
  while :; do
    sleep 2
    j=$(awsj ssm get-command-invocation --command-id "$cid" --instance-id "$id")
    _SHOW_MUTE=1   # show only the first poll
    st=$(jq -r '.Status // empty' <<<"$j" 2>/dev/null)
    case "$st" in
      ""|Pending|InProgress|Delayed|Cancelling)
        if [ $(( $(date +%s) - start )) -ge "$SSM_TIMEOUT" ]; then
          _SHOW_MUTE=$mute; echo "SSM: no result from $id after ${SSM_TIMEOUT}s (command $cid)" >&2; return 1
        fi ;;
      *) break ;;
    esac
  done
  _SHOW_MUTE=$mute
  jq -j '.StandardOutputContent // ""' <<<"$j"
  jq -j '.StandardErrorContent // ""' <<<"$j" >&2
  rc=$(jq -r '.ResponseCode // 1' <<<"$j")
  [ "$rc" -ge 0 ] 2>/dev/null || rc=1   # -1 = not executed
  return "$rc"
}

# Run a command on a competitor instance: through SSM when the instance is managed by
# Systems Manager (instances without a key pair), otherwise through SSH
rssh() {
  local ip="$1"; shift
  if [ "$REMOTE_MODE" != ssh ]; then
    local id; id=$(ec2_id_by_ip "$ip")
    if [ -n "$id" ] && { [ "$REMOTE_MODE" = ssm ] || ssm_online "$id"; }; then
      rssm "$id" "$@"; return
    fi
    [ "$REMOTE_MODE" = ssm ] && { echo "SSM: no running instance with private IP $ip" >&2; return 1; }
  fi
  local opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10
              -o LogLevel=ERROR -o ServerAliveInterval=15 -p "$SSH_PORT")
  [ -n "$SSH_KEY" ] && opts+=(-i "$SSH_KEY")
  if [ "$SHOW_CMDS" = 1 ] && [ "$_SHOW_MUTE" = 0 ]; then
    local d; d=$(shq ssh -p "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$SSH_USER@$ip")
    if [[ "$*" == *$'\n'* ]]; then   # multi-line remote script -> here-doc form
      show_raw "$d 'bash -s' <<'REMOTE'"$'\n'"$(sed -E 's/^[[:space:]]+//' <<<"$*")"$'\n'"REMOTE"
    else
      show_raw "$d $(shq "$*")"
    fi
  fi
  if [ -n "$SSH_PASS" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$SSH_PASS" ssh "${opts[@]}" "$SSH_USER@$ip" "$@"
  else
    ssh "${opts[@]}" "$SSH_USER@$ip" "$@" </dev/tty
  fi
}

# Install stress on a remote instance and start it in the background (killed after $3 seconds)
remote_stress() {
  local ip="$1" cpus="$2" secs="${3:-900}"
  rssh "$ip" "command -v stress >/dev/null 2>&1 || { sudo amazon-linux-extras install -y epel >/dev/null 2>&1; sudo yum install -y stress >/dev/null 2>&1 || sudo dnf install -y stress-ng >/dev/null 2>&1; };
              if command -v stress >/dev/null 2>&1; then B=stress; else B=stress-ng; fi;
              sudo nohup timeout $secs \$B -c $cpus >/dev/null 2>&1 &
              sleep 2; pgrep -f 'stress' >/dev/null && echo STRESS_RUNNING"
}
remote_stress_stop() { rssh "$1" "sudo pkill -f stress >/dev/null 2>&1; true"; }

ec2_ips_by_name() {   # private IPs of running instances with tag Name=$1
  awst ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
       --query "Reservations[].Instances[].PrivateIpAddress"
}
ec2_ids_by_name() {
  awst ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running" \
       --query "Reservations[].Instances[].InstanceId"
}

record() {   # id name max got
  RES_ID+=("$1"); RES_NAME+=("$2"); RES_MAX+=("$3"); RES_GOT+=("$4"); RES_NOTE+=("$NOTE")
}

list_aspects() {
  printf '%-7s %-45s %s\n' ID Aspect Max
  local a id name max fn
  for a in "${ASPECTS[@]}"; do
    IFS='|' read -r id name max fn <<<"$a"
    printf '%-7s %-45s %s\n' "$id" "$name" "$max"
  done
  printf '%-7s %-45s %s\n' "" "TOTAL" "$(printf '%s\n' "${ASPECTS[@]}" | awk -F'|' '{s+=$3} END{printf "%.1f", s}')"
}

summary() {
  local csv="$OUT_DIR/grade_${MODULE}_${STAMP}.csv" i got_total max_total
  section "SUMMARY - Module $MODULE ($MODULE_NAME)"
  printf '%-7s %-45s %6s %6s\n' ID Aspect Max Mark
  echo "ID;Aspect;Max;Mark;Notes" >"$csv"
  for i in "${!RES_ID[@]}"; do
    local col="$C_G"; [ "${RES_GOT[$i]}" = 0 ] && col="$C_R"
    printf '%-7s %-45s %6s %s%6s%s\n' "${RES_ID[$i]}" "${RES_NAME[$i]:0:45}" "${RES_MAX[$i]}" "$col" "${RES_GOT[$i]}" "$C_0"
    printf '%s;%s;%s;%s;%s\n' "${RES_ID[$i]}" "${RES_NAME[$i]}" "${RES_MAX[$i]}" "${RES_GOT[$i]}" "${RES_NOTE[$i]//;/,}" >>"$csv"
  done
  max_total=$(printf '%s\n' "${RES_MAX[@]}" | awk '{s+=$1} END{printf "%.1f", s}')
  got_total=$(printf '%s\n' "${RES_GOT[@]}" | awk '{s+=$1} END{printf "%.1f", s}')
  printf '%-7s %-45s %6s %s%6s%s\n' "" "TOTAL" "$max_total" "$C_B" "$got_total" "$C_0"
  echo ";TOTAL;$max_total;$got_total;" >>"$csv"
  echo
  echo "CSV: $csv"
  echo "Log: $LOG"
  [ -n "$CMD_FILE" ] && echo "Commands: $CMD_FILE"
}

run_all() {
  [ "$LIST" = 1 ] && { list_aspects; exit 0; }
  LOG="$OUT_DIR/grade_${MODULE}_${STAMP}.log"
  exec > >(tee -a "$LOG") 2>&1
  exec 3>&1
  if [ "$SHOW_CMDS" = 1 ]; then
    CMD_FILE="$OUT_DIR/grade_${MODULE}_${STAMP}_commands.txt"
    echo "# Commands executed - Module $MODULE ($MODULE_NAME) - region $AWS_DEFAULT_REGION - $(date '+%Y-%m-%d %H:%M:%S %Z')" >"$CMD_FILE"
  fi
  echo "Module $MODULE - $MODULE_NAME | region $AWS_DEFAULT_REGION | $(date '+%Y-%m-%d %H:%M:%S %Z')"
  local a id name max fn
  for a in "${ASPECTS[@]}"; do
    IFS='|' read -r id name max fn <<<"$a"
    selected "$id" || continue
    section "$id  $name  [$max]"
    [ -n "$CMD_FILE" ] && printf '\n# ===== %s  %s  [%s]\n' "$id" "$name" "$max" >>"$CMD_FILE"
    NOTE=""
    if "$fn"; then record "$id" "$name" "$max" "$max"; else record "$id" "$name" "$max" 0; fi
  done
  summary
}

# ============================================================================
#  Module B - Automation / CI-CD (Korea 2021 National - Task 2)
#  Run on the competitor's Bastion. The Bastion needs AWS permissions and
#  docker (the task requires docker on the Bastion for grading).
# ============================================================================
MODULE=B
MODULE_NAME="Automation"

REPO=wsi-api-repo
PIPELINE=wsi-api-pipeline
NEW_NAME="${NEW_NAME:-wsi-api-9847}"
LB_NAME="${LB_NAME:-wsi-api-alb}"        # not fixed by the task - asked if not found
TG_NAME="${TG_NAME:-wsi-api-tg}"         # not fixed by the task - asked if not found
APP_PORT="${APP_PORT:-80}"               # port of the app on the EC2 instances
CONTAINER_PORT="${CONTAINER_PORT:-80}"   # port exposed by the Docker image
MAIN_HASH=wsi-ffad-9642
RELEASE_HASH=wsi-release-ffaa

# ---------------------------------------------------------------- helpers
subnet_q() { awst ec2 describe-subnets --filters "Name=tag:Name,Values=$1" --query "Subnets[].$2"; }
default_route() { awst ec2 describe-route-tables --filters "Name=tag:Name,Values=$1" --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0'].$2"; }

lb_name() { cached lb_name _lb_name; }
_lb_name() {
  local n="$LB_NAME"
  if [ -z "$(awst elbv2 describe-load-balancers --names "$n" --query 'LoadBalancers[].LoadBalancerArn')" ]; then
    warn "load balancer '$n' not found. Existing: $(echo $(awst elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'))" >&2
    read -r -p "   Load balancer name created by the competitor: " n </dev/tty
  fi
  echo "$n"
}
tg_arn() { cached tg_arn _tg_arn; }
_tg_arn() {
  local n="$TG_NAME" a
  a=$(awst elbv2 describe-target-groups --names "$n" --query "TargetGroups[].TargetGroupArn" | head -1)
  if [ -z "$a" ]; then
    warn "target group '$n' not found. Existing: $(echo $(awst elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName'))" >&2
    read -r -p "   Target group name created by the competitor: " n </dev/tty
    a=$(awst elbv2 describe-target-groups --names "$n" --query "TargetGroups[].TargetGroupArn" | head -1)
  fi
  echo "$a"
}
lb_dns() { awst elbv2 describe-load-balancers --names "$(lb_name)" --query "LoadBalancers[].DNSName" | head -1; }
health() { curl -s --max-time 5 "http://$(lb_dns)/health"; }

DOCKER=docker
docker_cmd() { docker ps >/dev/null 2>&1 && DOCKER=docker || DOCKER="sudo docker"; }

# Replace the "ret = {...}" line of src/app.py on a branch and commit it.
# Prints the new commit id.
commit_ret() {   # branch hash
  local branch="$1" hash="$2" parent tmp n
  parent=$(awst codecommit get-branch --repository-name "$REPO" --branch-name "$branch" --query branch.commitId)
  [ -z "$parent" ] && { bad "branch $branch not found" >&2; return 1; }
  tmp=$(mktemp)
  aws codecommit get-file --repository-name "$REPO" --commit-specifier "$branch" --file-path src/app.py \
      --query fileContent --output text 2>/dev/null | base64 -d >"$tmp"
  n=$(grep -cE "^[[:space:]]*ret[[:space:]]*=[[:space:]]*\{" "$tmp")
  if [ "$n" = 1 ]; then
    sed -i -E "s/^([[:space:]]*)ret[[:space:]]*=[[:space:]]*\{.*\}/\1ret = {'hash': '$hash', 'code': 200}/" "$tmp"
    info "$(grep -nE "ret = \{'hash'" "$tmp")" >&2
    aws codecommit put-file --repository-name "$REPO" --branch-name "$branch" --file-path src/app.py \
        --file-content "fileb://$tmp" --parent-commit-id "$parent" --commit-message "grading $hash" \
        --name grader --email grader@example.com --query commitId --output text 2>/dev/null
  else
    warn "found $n 'ret = {...}' lines in src/app.py ($branch) - edit it manually:" >&2
    warn "set  ret = {'hash': '$hash', 'code': 200}  and commit on branch $branch" >&2
    pause "Commit the change in the CodeCommit console, then" >&2
    local now; now=$(awst codecommit get-branch --repository-name "$REPO" --branch-name "$branch" --query branch.commitId)
    [ "$now" != "$parent" ] && echo "$now"
  fi
  rm -f "$tmp"
}

exec_for_commit() {   # commitId -> status of the pipeline execution for it
  awsj codepipeline list-pipeline-executions --pipeline-name "$PIPELINE" --max-items 10 | \
    jq -r --arg c "$1" '[.pipelineExecutionSummaries[] | select(any(.sourceRevisions[]?; .revisionId==$c))][0].status // empty'
}

# ---------------------------------------------------------------- B1 Networking
b1_1() { expect "wsi-vpc CIDR" "$(awst ec2 describe-vpcs --filters Name=tag:Name,Values=wsi-vpc --query 'Vpcs[].CidrBlock')" "10.1.0.0/16"; }
b1_2() { expect "wsi-public-a CIDR" "$(subnet_q wsi-public-a CidrBlock)" "10.1.2.0/24"; }
b1_3() { expect "wsi-private-a CIDR" "$(subnet_q wsi-private-a CidrBlock)" "10.1.0.0/24"; }
b1_4() { expect "wsi-public-a AZ" "$(subnet_q wsi-public-a AvailabilityZone)" "${AWS_DEFAULT_REGION}a"; }
b1_5() { expect "wsi-private-b AZ" "$(subnet_q wsi-private-b AvailabilityZone)" "${AWS_DEFAULT_REGION}b"; }
b1_6() { expect_match "wsi-private-a-rt 0.0.0.0/0" "$(default_route wsi-private-a-rt NatGatewayId)" '^nat-'; }
b1_7() {
  local a b; a=$(default_route wsi-private-a-rt NatGatewayId); b=$(default_route wsi-private-b-rt NatGatewayId)
  expect_match "wsi-private-b-rt 0.0.0.0/0" "$b" '^nat-' || return 1
  [ "$a" != "$b" ] && { ok "different NAT gateway from private-a ($a)"; return 0; }
  bad "same NAT gateway as wsi-private-a-rt"; return 1
}
b1_8() { expect_match "wsi-public-rt 0.0.0.0/0" "$(default_route wsi-public-rt GatewayId)" '^igw-'; }

# ---------------------------------------------------------------- B2 EC2
b2_1() {
  local names; names=$(awsj ec2 describe-instances --filters "Name=tag:wsi:deploy:group,Values=dev-api" \
        "Name=instance-state-name,Values=pending,running,stopped" | jq -r '.Reservations[].Instances[].Tags[]? | select(.Key=="Name") | .Value')
  info "instances: $(echo $names)"
  has_line wsi-api-1 "$names" && has_line wsi-api-2 "$names" && { ok "wsi-api-1 and wsi-api-2 found"; return 0; }
  bad "wsi-api-1 / wsi-api-2 with tag wsi:deploy:group=dev-api not found"; return 1
}
b2_2() {
  expect_match "wsi-api-1 instance profile" "$(awst ec2 describe-instances --filters Name=tag:Name,Values=wsi-api-1 \
     --query 'Reservations[].Instances[].IamInstanceProfile.Arn' | head -1)" '^arn:aws:iam::[0-9]{12}:instance-profile/wsi-api$'
}

# ---------------------------------------------------------------- B3 LB
b3_1() { expect "$(lb_name) type" "$(awst elbv2 describe-load-balancers --names "$(lb_name)" --query 'LoadBalancers[].Type')" "application"; }
b3_2() {
  local arn st; arn=$(tg_arn); [ -z "$arn" ] && { bad "target group not found"; return 1; }
  st=$(awst elbv2 describe-target-health --target-group-arn "$arn" --query "TargetHealthDescriptions[].TargetHealth.State")
  info "targets: $(echo $st)"
  [ "$(grep -cx healthy <<<"$st")" -ge 2 ] && { ok "2 healthy targets"; return 0; }
  bad "less than 2 healthy targets"; return 1
}
b3_3() {
  local h; h=$(health); info "response: $h"
  jq -e '.status=="ok"' >/dev/null 2>&1 <<<"$h" && { ok '{"status":"ok"}'; return 0; }
  bad 'expected {"status":"ok"}'; return 1
}

# ---------------------------------------------------------------- B4 CodeCommit
b4_1() { expect "repository" "$(awst codecommit get-repository --repository-name "$REPO" --query repositoryMetadata.repositoryName)" "$REPO"; }
b4_2() { expect "default branch" "$(awst codecommit get-repository --repository-name "$REPO" --query repositoryMetadata.defaultBranch)" "main"; }
b4_3() {
  local r=0 f
  for f in src/app.py appspec.yml; do
    if aws codecommit get-file --repository-name "$REPO" --commit-specifier main --file-path "$f" >/dev/null 2>&1; then
      ok "$f present on main"; else bad "$f missing on main"; r=1; fi
  done
  return $r
}

# ---------------------------------------------------------------- B5 CodeBuild
b5_1() { expect "project" "$(awst codebuild batch-get-projects --names wsi-api-build --query 'projects[].name')" "wsi-api-build"; }
b5_2() {
  local st id g s
  st=$(awst codebuild batch-get-projects --names wsi-api-build --query 'projects[].logsConfig.cloudWatchLogs.status')
  info "CloudWatch logs: ${st:-ENABLED (default)}"
  [ "${st:-ENABLED}" = ENABLED ] || { bad "CloudWatch logs disabled"; return 1; }
  id=$(awst codebuild list-builds-for-project --project-name wsi-api-build --sort-order DESCENDING --query 'ids[0]')
  [ -z "$id" ] && { bad "no build has been run yet"; return 1; }
  g=$(awst codebuild batch-get-builds --ids "$id" --query 'builds[0].logs.groupName')
  s=$(awst codebuild batch-get-builds --ids "$id" --query 'builds[0].logs.streamName')
  info "latest build $id -> $g / $s"
  [ -n "$g" ] && [ -n "$(awst logs get-log-events --log-group-name "$g" --log-stream-name "$s" --limit 3 --query 'events[].message')" ] \
    && { ok "build log is available"; return 0; }
  bad "build log not available"; return 1
}

# ---------------------------------------------------------------- B6 CodeDeploy
b6_1() { expect "application" "$(awst deploy get-application --application-name wsi-api --query application.applicationName)" "wsi-api"; }
b6_2() { expect "deployment type" "$(awst deploy get-deployment-group --application-name wsi-api --deployment-group-name dev-api --query deploymentGroupInfo.deploymentStyle.deploymentType)" "IN_PLACE"; }
b6_3() {
  local j; j=$(awsj deploy get-deployment-group --application-name wsi-api --deployment-group-name dev-api)
  jq -e '[.deploymentGroupInfo.ec2TagSet.ec2TagSetList[]?[]?, .deploymentGroupInfo.ec2TagFilters[]?]
         | any(.Key=="wsi:deploy:group" and .Value=="dev-api")' >/dev/null 2>&1 <<<"$j" \
    && { ok "target tag wsi:deploy:group=dev-api"; return 0; }
  bad "deployment group does not target wsi:deploy:group=dev-api"; return 1
}

# ---------------------------------------------------------------- B7 CodePipeline
b7_1() { has_line "$PIPELINE" "$(awst codepipeline list-pipelines --query 'pipelines[].name')" && { ok "$PIPELINE found"; return 0; }; bad "$PIPELINE not found"; return 1; }
b7_2() {
  local j s p; j=$(awsj codepipeline get-pipeline --name "$PIPELINE")
  s=$(jq -r '[.pipeline.stages[].name] | join(",")' <<<"$j"); p=$(jq -r '[.pipeline.stages[].actions[0].actionTypeId.provider] | join(",")' <<<"$j")
  expect "stages" "$s" "Source,Build,Deploy"; local r=$?
  expect "providers" "$p" "CodeCommit,CodeBuild,CodeDeploy" || r=1
  return $r
}
b7_3() {
  local id st
  id=$(awst codepipeline start-pipeline-execution --name "$PIPELINE" --query pipelineExecutionId)
  [ -z "$id" ] && { bad "could not start the pipeline"; return 1; }
  info "execution $id"
  pipe_done() { st=$(awst codepipeline get-pipeline-execution --pipeline-name "$PIPELINE" --pipeline-execution-id "$id" --query pipelineExecution.status); [[ "$st" =~ ^(Succeeded|Failed|Stopped|Superseded)$ ]]; }
  wait_for 900 20 "pipeline execution (max 15 min)" pipe_done
  expect "execution status" "$st" "Succeeded"
}
b7_4() {
  [ -x /opt/ec2_launch.sh ] || { bad "/opt/ec2_launch.sh not found or not executable"; return 1; }
  info "running /opt/ec2_launch.sh $NEW_NAME"
  show_cmd /opt/ec2_launch.sh "$NEW_NAME"
  /opt/ec2_launch.sh "$NEW_NAME" 2>&1 | sed 's/^/     | /' | tail -5
  tag_ok() { awsj ec2 describe-instances --filters "Name=tag:Name,Values=$NEW_NAME" | \
             jq -e '[.Reservations[].Instances[].Tags[]?] | any(.Key=="wsi:deploy:group" and .Value=="dev-api")' >/dev/null; }
  wait_for 120 10 "$NEW_NAME with tag wsi:deploy:group=dev-api" tag_ok && { ok "$NEW_NAME created"; return 0; }
  bad "$NEW_NAME not created with the required tags"; return 1
}
b7_5() {
  confirm "Commit ret = {'hash': '$MAIN_HASH', ...} to src/app.py on main?" || { bad "skipped"; return 1; }
  local c st; c=$(commit_ret main "$MAIN_HASH"); [ -z "$c" ] && { bad "commit failed"; return 1; }
  info "commit $c"
  done_c() { st=$(exec_for_commit "$c"); [[ "$st" =~ ^(Succeeded|Failed|Stopped|Superseded)$ ]]; }
  wait_for 900 20 "pipeline triggered by the commit (max 15 min)" done_c || { bad "pipeline did not finish (status: ${st:-not started})"; return 1; }
  expect "execution status" "$st" "Succeeded" || return 1
  hash_ok() { grep -q "$MAIN_HASH" <<<"$(health)"; }
  wait_for 90 10 "new version behind the load balancer" hash_ok
  info "response: $(health)"
  hash_ok && { ok "LB returns $MAIN_HASH"; return 0; }; bad "LB does not return $MAIN_HASH"; return 1
}
b7_6() {
  local ip out; ip=$(ec2_ips_by_name "$NEW_NAME" | head -1); [ -z "$ip" ] && { bad "$NEW_NAME not running"; return 1; }
  out=$(rssh "$ip" "curl -s --max-time 5 http://localhost:$APP_PORT/health"); info "response: $out"
  grep -q "$MAIN_HASH" <<<"$out" && { ok "new instance runs the new version"; return 0; }
  bad "new instance does not return $MAIN_HASH"; return 1
}
b7_7() {
  local id t; id=$(ec2_ids_by_name "$NEW_NAME" | head -1); [ -z "$id" ] && { bad "$NEW_NAME not running"; return 1; }
  t=$(awst elbv2 describe-target-health --target-group-arn "$(tg_arn)" --query "TargetHealthDescriptions[].Target.Id")
  info "targets: $(echo $t)"
  has_line "$id" "$t" && { ok "$id registered in the target group"; return 0; }
  bad "$id is not in the target group"; return 1
}

# ---------------------------------------------------------------- B8 ECR
b8_1() { expect "repository" "$(awst ecr describe-repositories --repository-names wsi-api-ecr --query 'repositories[].repositoryName')" "wsi-api-ecr"; }
kst_epoch() { local t="$1"; TZ=Asia/Seoul date -d "20${t:0:2}-${t:2:2}-${t:4:2} ${t:6:2}:${t:8:2}:${t:10:2}" +%s 2>/dev/null; }
b8_2() {
  confirm "Commit ret = {'hash': '$RELEASE_HASH', ...} to src/app.py on release?" || { bad "skipped"; return 1; }
  local before c t0 new; before=$(awst ecr list-images --repository-name wsi-api-ecr --query 'imageIds[].imageTag')
  c=$(commit_ret release "$RELEASE_HASH"); [ -z "$c" ] && { bad "commit failed"; return 1; }
  t0=$(date +%s); info "commit $c at $(TZ=Asia/Seoul date +%y%m%d%H%M%S) KST"
  new_tag() { NEW_TAG=$(comm -13 <(sort <<<"$before") <(awst ecr list-images --repository-name wsi-api-ecr --query 'imageIds[].imageTag' | sort) | grep -E '^[0-9]{12}$' | tail -1); [ -n "$NEW_TAG" ]; }
  wait_for 300 15 "new image in ECR (max 5 min)" new_tag || { bad "no new image within 5 minutes"; return 1; }
  local e; e=$(kst_epoch "$NEW_TAG"); info "new tag $NEW_TAG"
  [ -n "$e" ] && [ $(( e > t0 ? e - t0 : t0 - e )) -le 300 ] && { ok "tag matches the build time (KST)"; return 0; }
  bad "tag $NEW_TAG is not the current KST date/time (YYMMDDhhmmss)"; return 1
}
b8_3() {
  docker_cmd
  local uri tag reg cid out
  uri=$(awst ecr describe-repositories --repository-names wsi-api-ecr --query 'repositories[].repositoryUri')
  tag=${NEW_TAG:-$(awst ecr list-images --repository-name wsi-api-ecr --query 'imageIds[].imageTag' | grep -E '^[0-9]{12}$' | sort | tail -1)}
  [ -z "$uri" ] || [ -z "$tag" ] && { bad "repository or image tag not found"; return 1; }
  reg=${uri%%/*}; info "image $uri:$tag"
  aws ecr get-login-password | $DOCKER login --username AWS --password-stdin "$reg" >/dev/null 2>&1 || { bad "docker login failed"; return 1; }
  $DOCKER pull "$uri:$tag" >/dev/null 2>&1 || { bad "docker pull failed"; return 1; }
  $DOCKER rm -f grade-b8 >/dev/null 2>&1
  cid=$($DOCKER run -d --name grade-b8 -p 28888:"$CONTAINER_PORT"/tcp "$uri:$tag" 2>&1) || { bad "docker run failed: $cid"; return 1; }
  up() { out=$(curl -s --max-time 3 http://localhost:28888/health); [ -n "$out" ]; }
  wait_for 30 3 "container answering on :28888" up
  info "response: $out"
  $DOCKER rm -f grade-b8 >/dev/null 2>&1
  grep -q "$RELEASE_HASH" <<<"$out" && { ok "image runs the release version"; return 0; }
  bad "expected $RELEASE_HASH in the response"; return 1
}

aspect B1.1 "VPC" 0.6 b1_1
aspect B1.2 "Public Subnet" 0.8 b1_2
aspect B1.3 "Private Subnet" 0.8 b1_3
aspect B1.4 "Public HA configuration" 0.8 b1_4
aspect B1.5 "Private HA configuration" 0.8 b1_5
aspect B1.6 "NAT Gateway - Private A" 0.4 b1_6
aspect B1.7 "NAT Gateway - Private B" 0.4 b1_7
aspect B1.8 "Int Gateway - Public" 0.8 b1_8
aspect B2.1 "EC2 creation confirmation" 1.1 b2_1
aspect B2.2 "Check IAM role" 1.1 b2_2
aspect B3.1 "Verify LB creation" 1.1 b3_1
aspect B3.2 "Check healthy EC2" 1.1 b3_2
aspect B3.3 "Verify application call" 1.1 b3_3
aspect B4.1 "Verify code commit creation" 0.9 b4_1
aspect B4.2 "Change default branch" 1.1 b4_2
aspect B4.3 "Verify source code upload" 1.0 b4_3
aspect B5.1 "Verify code build generation" 0.8 b5_1
aspect B5.2 "Check the build log" 1.1 b5_2
aspect B6.1 "Verify code deploy creation" 1.1 b6_1
aspect B6.2 "Check the deployment type" 1.1 b6_2
aspect B6.3 "Check the deploy target" 1.1 b6_3
aspect B7.1 "Confirm pipeline creation" 1.0 b7_1
aspect B7.2 "Check pipeline stage" 1.1 b7_2
aspect B7.3 "Pipeline manual trigger" 1.1 b7_3
aspect B7.4 "Deploy new instance" 1.1 b7_4
aspect B7.5 "CodeCommit trigger" 1.1 b7_5
aspect B7.6 "Verify new instance operation" 1.1 b7_6
aspect B7.7 "Check new instance LB" 1.1 b7_7
aspect B8.1 "Verify ECR creation" 1.1 b8_1
aspect B8.2 "Check Docker build" 1.1 b8_2
aspect B8.3 "Check Docker image" 1.1 b8_3

parse_args "$@"
[ "$LIST" = 1 ] || { need jq; need curl; need base64 coreutils; }
run_all
