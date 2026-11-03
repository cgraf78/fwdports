#!/usr/bin/env bash
# Exercise the one stock ET release whose private SSH-launch behavior fwdports
# relies on. Hermetic unit fakes test failure seams; this script intentionally
# runs the publisher's checksummed binary so those fakes cannot define truth.

set -uo pipefail

et_path=${1:-}
[[ $et_path == /* && -f $et_path && -x $et_path && ! -L $et_path ]] || {
  printf 'stock ET contract: pass an absolute ET executable path\n' >&2
  exit 64
}

fail() {
  printf 'stock ET contract: %s\n' "$1" >&2
  exit 1
}

version=$(LC_ALL=C "$et_path" --version 2>&1) ||
  fail 'version query failed'
[[ $version == *'et version 7.0.0'* ]] ||
  fail 'publisher artifact is not ET 7.0.0'
help=$(LC_ALL=C "$et_path" --help 2>&1) || fail 'help query failed'
for option in --port --tunnel --reversetunnel --jumphost --no-terminal --logdir \
  --logtostdout --telemetry --keepalive --terminal-path --command; do
  [[ $help == *"$option"* ]] || fail "missing required option: $option"
done

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/fwdports-stock-et.XXXXXXXX") ||
  fail 'cannot create temporary root'
et_pid=
listener_pid=
listener_count=0
cleanup() {
  [[ -z ${et_pid:-} ]] || kill -KILL "$et_pid" 2>/dev/null || true
  [[ -z ${et_pid:-} ]] || wait "$et_pid" 2>/dev/null || true
  [[ -z ${listener_pid:-} ]] || kill -KILL "$listener_pid" 2>/dev/null || true
  [[ -z ${listener_pid:-} ]] || wait "$listener_pid" 2>/dev/null || true
  case "$tmp_root" in
    "${TMPDIR:-/tmp}"/fwdports-stock-et.*) rm -rf -- "$tmp_root" ;;
  esac
}
trap cleanup EXIT
umask 077
mkdir -p "$tmp_root/bin" "$tmp_root/home" "$tmp_root/log" "$tmp_root/tmp"

# ET v7 looks up a command literally named ssh. The fixture records the exact
# argv and emits a syntactically valid one-use ET credential, but launches no
# remote command. ET resolves its config home through passwd rather than HOME;
# the publisher check therefore uses an ephemeral hosted runner and loopback
# target, while HOME only contains incidental child-process state.
# Single-quoted fixture lines are intentionally expanded by the child.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '{ printf "CALL\n"; printf "ARG=%s\n" "$@"; } >>"$FWDPORTS_STOCK_ET_SSH_LOG"' \
  'printf "%s\n" "IDPASSKEY:XXXXXXXXXXXXXXXX/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' \
  'exit 0' >"$tmp_root/bin/ssh"
chmod 0700 "$tmp_root/bin/ssh"

# A silent loopback peer keeps the real client alive after bootstrap. That
# makes TERM behavior observable without requiring or simulating etserver's
# private wire protocol.
cat >"$tmp_root/listener.py" <<'PY'
import socket
import sys
import time

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(1)
server_port = listener.getsockname()[1]
forward_ports = []
while len(forward_ports) < 2:
    candidate = socket.socket()
    candidate.bind(("127.0.0.1", 0))
    port = candidate.getsockname()[1]
    candidate.close()
    if port != server_port and port not in forward_ports:
        forward_ports.append(port)
with open(sys.argv[1], "w", encoding="ascii") as output:
    output.write(" ".join(str(port) for port in [server_port] + forward_ports))
    output.write("\n")
connection, _ = listener.accept()
with open(sys.argv[2], "w", encoding="ascii") as output:
    output.write("accepted\n")
time.sleep(30)
connection.close()
PY
# Run the real client once against a fresh silent peer, with both tunnel
# option forms. case_prefix and case_suffix hold the options under test around
# the tunnels; expected_terminal is the terminal path the SSH bootstrap must
# run, or empty for ET's default.
run_stock_et() {
  local label=$1 case_root
  listener_count=$((listener_count + 1))
  case_root=$tmp_root/case-$listener_count
  mkdir -p "$case_root" || fail "$label: cannot create case root"
  python3 "$tmp_root/listener.py" "$case_root/port" "$case_root/accepted" &
  listener_pid=$!
  for ((_attempt = 0; _attempt < 200; _attempt++)); do
    [[ ! -s $case_root/port ]] || break
    kill -0 "$listener_pid" 2>/dev/null || fail "$label: loopback peer exited early"
    sleep 0.05
  done
  [[ -s $case_root/port ]] || fail "$label: loopback peer did not publish its port"
  read -r port local_port remote_port <"$case_root/port" ||
    fail "$label: loopback peer published invalid ports"
  [[ -n $port && -n $local_port && -n $remote_port ]] ||
    fail "$label: loopback peer did not publish three ports"

  HOME=$tmp_root/home PATH=$tmp_root/bin:/usr/bin:/bin \
    TERM=xterm-256color TMPDIR=$tmp_root/tmp \
    FWDPORTS_STOCK_ET_SSH_LOG=$case_root/ssh-argv \
    "$et_path" --logdir "$tmp_root/log" --logtostdout \
    --telemetry=false --port "$port" \
    ${case_prefix[@]+"${case_prefix[@]}"} \
    --tunnel "127.0.0.1:$local_port:127.0.0.1:80" \
    --reversetunnel "127.0.0.1:$remote_port:127.0.0.1:81" \
    ${case_suffix[@]+"${case_suffix[@]}"} \
    127.0.0.1 >"$case_root/et-output" 2>&1 &
  et_pid=$!

  for ((_attempt = 0; _attempt < 200; _attempt++)); do
    [[ ! -s $case_root/ssh-argv || ! -s $case_root/accepted ]] || break
    kill -0 "$et_pid" 2>/dev/null || break
    sleep 0.05
  done
  [[ -s $case_root/ssh-argv ]] || {
    sed -n '1,120p' "$case_root/et-output" >&2
    fail "$label: real ET did not invoke the PATH ssh shim"
  }
  [[ -s $case_root/accepted ]] || fail "$label: real ET did not reach its configured port"

  line_count=$(wc -l <"$case_root/ssh-argv")
  line_count=${line_count//[[:space:]]/}
  [[ $line_count == 3 && $(sed -n '1p' "$case_root/ssh-argv") == CALL ]] ||
    fail "$label: real ET did not make exactly one two-argument SSH bootstrap"
  destination=$(sed -n '2s/^ARG=//p' "$case_root/ssh-argv")
  remote_command=$(sed -n '3s/^ARG=//p' "$case_root/ssh-argv")
  [[ $destination == *@127.0.0.1 ]] ||
    fail "$label: real ET SSH destination shape changed"
  [[ $remote_command == *etterminal* &&
    $remote_command == *xterm-256color* ]] ||
    fail "$label: real ET remote bootstrap shape changed"
  [[ -z $expected_terminal || $remote_command == *"' | $expected_terminal --verbose="* ]] ||
    fail "$label: real ET did not launch the remote terminal through: $expected_terminal"

  # The silent peer should hold the client in its foreground reconnect lifetime.
  # Observe a short stable interval before TERM so an already-exited client can
  # never satisfy the shutdown assertion below.
  for ((_attempt = 0; _attempt < 5; _attempt++)); do
    kill -0 "$et_pid" 2>/dev/null || {
      sed -n '1,120p' "$case_root/et-output" >&2
      fail "$label: real ET exited before the TERM check"
    }
    sleep 0.05
  done
  kill -TERM "$et_pid" 2>/dev/null || true
  for ((_attempt = 0; _attempt < 100; _attempt++)); do
    kill -0 "$et_pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$et_pid" 2>/dev/null; then
    fail "$label: real ET did not stop within five seconds of TERM"
  fi
  wait "$et_pid" 2>/dev/null || true
  et_pid=
  kill -KILL "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  listener_pid=
}

# fwdports' own et driver.
case_prefix=(--no-terminal)
case_suffix=()
expected_terminal=
run_stock_et 'et driver'

# ettun's stock argv, exactly as ettun-et-gate.sh pins it. --no-persist is an
# ET 7.1 option that 7.0 must ignore without consuming the next argument, and
# the terminal path must reach the remote bootstrap verbatim so the login
# shell starts with NO_TMUX=1.
case_prefix=(--no-terminal --no-persist --keepalive 5
  --terminal-path 'env NO_TMUX=1 etterminal')
case_suffix=(--command 'true')
expected_terminal='env NO_TMUX=1 etterminal'
run_stock_et 'ettun stock argv'

printf 'stock ET contract: ET 7.0.0 publisher artifact passed\n'
