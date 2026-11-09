#!/usr/bin/env bash
# Read-only hardening checks against a running KrewOS container.
#
#   bash scripts/container-security-check.sh [CONTAINER] [--brew]
#
# CONTAINER defaults to the compose service `krewos`. `--brew` also runs
# `brew install hello` as the sandbox user (network + a few minutes; writes only to the
# linuxbrew volume). Exit code is non-zero when any check fails.
set -euo pipefail
export MSYS_NO_PATHCONV=1

AGENT_UID=20001
AGENT_TWO_UID=20002
MCP_UID=10001
BROWSER_UID=10002
BREW_UID=10003
NGINX_UID=10004
container=""
run_brew=0
for arg in "$@"; do
  case "$arg" in
    --brew) run_brew=1 ;;
    -h | --help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) container="$arg" ;;
  esac
done
if [[ -z "$container" ]]; then
  container="$(docker ps --filter label=com.docker.compose.service=krewos --format '{{.Names}}' | head -n1)"
fi
if [[ -z "$container" ]]; then
  echo "no running krewos container found (pass its name as the first argument)" >&2
  exit 2
fi

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
check() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}
inspect() { docker inspect --format "$1" "$container"; }
cleanup() {
  if [[ -n "$container" ]]; then
    docker exec --user "${AGENT_UID}:${BROWSER_UID}" "$container" /bin/bash -c 'rm -rf /workspace/.check-agent1' >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Same scrubbed env as shell_exec (docker exec would otherwise inherit the image ENV).
as_uid() {
  local uid="$1"
  local home="$2"
  local cmd="$3"
  docker exec --user "${uid}:${uid}" "$container" /bin/bash -c \
    'exec env -i PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin HOME="$1" \
      HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
      NO_PROXY="${NO_PROXY:-}" http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" \
      no_proxy="${no_proxy:-}" /bin/bash -c "$2"' _ "$home" "$cmd"
}
as_agent() { as_uid "$AGENT_UID" /workspace/.check-agent1 "$1"; }
as_agent_two() { as_uid "$AGENT_TWO_UID" /workspace/.check-agent2 "$1"; }
agent_cannot() { ! as_agent "$1" >/dev/null 2>&1; }
agent_two_cannot() { ! as_agent_two "$1" >/dev/null 2>&1; }
rootfs_has_no() {
  ! as_agent "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; $1" >/dev/null 2>&1
}
contains() { grep -q -- "$2" <<<"$1"; }
not_contains() { ! contains "$@"; }
only_proxy_ports_published() {
  local p
  for p in $1; do
    case "$p" in
      8080/tcp | 8443/tcp) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

echo "== container: $container"

echo "-- runtime configuration (docker inspect)"
check "not privileged" test "$(inspect '{{.HostConfig.Privileged}}')" = "false"
check "cap_drop ALL" contains "$(inspect "{{.HostConfig.CapDrop}}")" ALL
cap_add="$(inspect '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' | sed 's/^CAP_//' | sort | xargs)"
check "cap_add is exactly KILL SETGID SETUID (got: ${cap_add:-none})" test "$cap_add" = "KILL SETGID SETUID"
secopt="$(inspect "{{.HostConfig.SecurityOpt}}")"
check "no-new-privileges" contains "$secopt" no-new-privileges
check "default seccomp profile (not unconfined)" not_contains "$secopt" "seccomp[:=]unconfined"
check "read-only root filesystem" test "$(inspect '{{.HostConfig.ReadonlyRootfs}}')" = "true"
check "network namespace is not host" test "$(inspect '{{.HostConfig.NetworkMode}}')" != "host"
check "pid namespace is not host" test "$(inspect '{{.HostConfig.PidMode}}')" != "host"
check "ipc namespace is not host" test "$(inspect '{{.HostConfig.IpcMode}}')" != "host"
check "pids limit set" test "$(inspect '{{.HostConfig.PidsLimit}}')" -gt 0
mounts="$(inspect '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}')"
check "no Docker socket mounted" not_contains "$mounts" docker.sock
bad_binds="$(grep '^bind ' <<<"$mounts" | grep -v 'rw=false' || true)"
check "host bind mounts are read-only" test -z "$bad_binds"
published_ports="$(inspect '{{range $p, $b := .HostConfig.PortBindings}}{{if $b}}{{println $p}}{{end}}{{end}}' | sort | xargs)"
check "only nginx TLS proxy ports (8080/tcp, 8443/tcp) published (got: ${published_ports:-none})" only_proxy_ports_published "$published_ports"

echo "-- distroless / hardened rootfs surface"
check "no setuid/setgid binaries in the image" test -z "$(as_agent 'find / -xdev -type f -perm /6000 2>/dev/null')"
check "no package manager (apt/apt-get/dpkg)" rootfs_has_no 'command -v apt || command -v apt-get || command -v dpkg'
check "no C/C++ compiler or preprocessor (gcc/g++/cc/cpp)" rootfs_has_no 'command -v gcc || command -v g++ || command -v cc || command -v cpp'
check "no user/password/mount admin tools (useradd/passwd/su/mount)" rootfs_has_no 'command -v useradd || command -v passwd || command -v su || command -v mount'
check "no python3 or websockify" rootfs_has_no 'command -v python3 || command -v websockify'
check "no sudo" rootfs_has_no 'command -v sudo'

echo "-- sandbox users (agent1=${AGENT_UID}, agent2=${AGENT_TWO_UID}, mcp=${MCP_UID}, browser=${BROWSER_UID}, linuxbrew=${BREW_UID}, nginx=${NGINX_UID})"
check "runs as uid ${AGENT_UID}" test "$(as_agent 'id -u')" = "$AGENT_UID"
check "agent uid ${AGENT_UID} is numeric-only (no /etc/passwd or /etc/group name)" test "$(as_agent 'id')" = "uid=${AGENT_UID} gid=${AGENT_UID} groups=${AGENT_UID}"
check "no effective capabilities" test "$(as_agent "awk '/^CapEff/ {print \$2}' /proc/self/status")" = "0000000000000000"
check "no_new_privs set" test "$(as_agent "awk '/^NoNewPrivs/ {print \$2}' /proc/self/status")" = "1"
check "cannot read root process environments (secrets)" agent_cannot 'for p in $(pgrep -u 0); do cat /proc/$p/environ; done | grep -q .'
check "cannot list data dir /var/lib/krewos" agent_cannot 'ls /var/lib/krewos'
check "cannot list MCP cache /var/cache/krewos-mcp" agent_cannot 'ls /var/cache/krewos-mcp'
check "cannot list browser profile/socket dir /var/lib/krewos-browser" agent_cannot 'ls /var/lib/krewos-browser'
check "cannot write /usr (read-only rootfs)" agent_cannot 'touch /usr/local/bin/x'
check "cannot write /etc" agent_cannot 'touch /etc/x'
check "cannot modify /home/linuxbrew binaries" agent_cannot 'touch /home/linuxbrew/.linuxbrew/bin/.write-check'
check "cannot signal the runtime" agent_cannot 'kill -0 1'
docker exec --user "${AGENT_UID}:${BROWSER_UID}" "$container" /bin/bash -c \
  'mkdir -p -m 2770 /workspace/.check-agent1 && chmod 2770 /workspace/.check-agent1'
check "can write own provisioned 2770 workspace" as_agent 'touch /workspace/.check-agent1/.write-check && rm /workspace/.check-agent1/.write-check'
check "second agent (${AGENT_TWO_UID}) cannot traverse or read agent1 (${AGENT_UID}) workspace" agent_two_cannot 'ls /workspace/.check-agent1'
docker exec --user "${AGENT_UID}:${BROWSER_UID}" "$container" /bin/bash -c 'rm -rf /workspace/.check-agent1'
check "prlimit available" as_agent 'command -v prlimit >/dev/null'
check "brew available" as_agent '/home/linuxbrew/.linuxbrew/bin/brew --version >/dev/null'
if [[ "$run_brew" == 1 ]]; then
  check "brew install hello" as_agent "brew install hello >/dev/null && hello"
fi

echo "-- in-container nginx & browser isolation"
check "nginx worker runs as uid ${NGINX_UID}" docker exec "$container" pgrep -u "$NGINX_UID" nginx >/dev/null
check "agent cannot access X11 display :99" agent_cannot 'DISPLAY=:99 xprop -root'
check "agent cannot connect to raw CDP :9222" agent_cannot 'curl -fsS -m 2 http://127.0.0.1:9222/json/version'
check "agent cannot call browser MCP :8931 without internal token" agent_cannot 'curl -fsS -m 2 http://127.0.0.1:8931/mcp'
if docker exec "$container" pgrep -u "$BROWSER_UID" Xtigervnc >/dev/null 2>&1; then
  check "browser Xtigervnc runs as uid ${BROWSER_UID}" docker exec "$container" pgrep -u "$BROWSER_UID" Xtigervnc >/dev/null
fi

echo "-- instance metadata (IMDS)"
if as_agent 'curl -s --connect-timeout 1 -m 1 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token | grep -q .' 2>/dev/null; then
  fail "IMDSv2 token obtainable from the container (set HttpPutResponseHopLimit=1 on the instance)"
else
  pass "IMDSv2 token not obtainable from the container"
fi
if as_agent 'curl -s --connect-timeout 1 -m 1 -o /dev/null -w "%{http_code}" http://169.254.169.254/latest/meta-data/ | grep -q "^200$"' 2>/dev/null; then
  fail "IMDSv1 reachable from the container (set HttpTokens=required)"
else
  pass "IMDSv1 not reachable"
fi

echo "== ${failures} failure(s)"
if [[ "$failures" -ne 0 ]]; then
  exit 1
fi
