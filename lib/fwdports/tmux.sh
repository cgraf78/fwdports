#!/usr/bin/env bash
# Tmux execution primitives. Commands cross this boundary only as argv arrays;
# constructing a shell string here would undo the parser and driver API's
# validation and would make process ownership evidence describe a shell rather
# than the lifetime process fwdports actually intends to supervise.

_fwdports_tmux_call() {
  local tmux_path=$1 socket=$2
  shift 2

  # Emptying these variables keeps an inherited client context from silently
  # selecting or nesting inside the user's live server. The explicit private
  # socket and null configuration are the actual isolation boundary.
  TMUX='' TMUX_PANE='' "$tmux_path" -S "$socket" -f /dev/null "$@"
}

fwdports_tmux_create_session() {
  local tmux_path=$1 socket=$2 session_name=$3 nonce=$4 start_directory=$5
  local output session_id pane_id recorded_nonce recorded_session
  shift 5

  [[ -x "$tmux_path" && $# -gt 0 ]] || {
    printf 'fwdports: tmux or initial pane command is unavailable\n' >&2
    return 1
  }
  case "$socket" in
    /*) ;;
    *)
      printf 'fwdports: tmux socket path must be absolute\n' >&2
      return 1
      ;;
  esac
  [[ $socket != *$'\n'* && $socket != *$'\r'* && $socket != *$'\t'* &&
    -d "${socket%/*}" && ! -L "${socket%/*}" ]] || {
    printf 'fwdports: tmux socket parent is unsafe\n' >&2
    return 1
  }
  [[ $session_name =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || {
    printf 'fwdports: tmux session name is unsafe\n' >&2
    return 1
  }
  [[ $nonce =~ ^generation\.[A-Za-z0-9]+$ ]] || {
    printf 'fwdports: tmux generation nonce is invalid\n' >&2
    return 1
  }
  [[ -d "$start_directory" && ! -L "$start_directory" ]] || {
    printf 'fwdports: tmux start directory is unavailable\n' >&2
    return 1
  }

  # `new-session -e` installs the nonce in the same server transaction that
  # creates the session. A later set-environment call would leave a window in
  # which a same-name session existed without ownership evidence.
  output=$(_fwdports_tmux_call "$tmux_path" "$socket" \
    new-session -d -P -F '#{session_id}:#{pane_id}' \
    -s "$session_name" -c "$start_directory" \
    -e "FWDPORTS_GENERATION=$nonce" -- "$@") || return 1
  case "$output" in
    \$[0-9]*:%[0-9]*) ;;
    *)
      printf 'fwdports: tmux returned invalid session identity\n' >&2
      return 1
      ;;
  esac
  session_id=${output%%:*}
  pane_id=${output#*:}

  # Validate the relationship before returning any authority to the caller.
  # If validation fails, remove only the just-created ID on this private
  # socket; names and process patterns are never used as cleanup authority.
  recorded_nonce=$(_fwdports_tmux_call "$tmux_path" "$socket" \
    show-environment -t "$session_id" FWDPORTS_GENERATION) || {
    _fwdports_tmux_call "$tmux_path" "$socket" \
      kill-session -t "$session_id" 2>/dev/null || true
    return 1
  }
  recorded_session=$(_fwdports_tmux_call "$tmux_path" "$socket" \
    display-message -p -t "$pane_id" '#{session_id}') || {
    _fwdports_tmux_call "$tmux_path" "$socket" \
      kill-session -t "$session_id" 2>/dev/null || true
    return 1
  }
  if [[ $recorded_nonce != "FWDPORTS_GENERATION=$nonce" ||
    $recorded_session != "$session_id" ]]; then
    _fwdports_tmux_call "$tmux_path" "$socket" \
      kill-session -t "$session_id" 2>/dev/null || true
    printf 'fwdports: tmux session ownership could not be verified\n' >&2
    return 1
  fi

  # Retaining a dead pane lets the controller report the real exit status. It
  # is set immediately while the lifetime fixture/process is still present;
  # production runners remain foreground processes and do not self-daemonize.
  _fwdports_tmux_call "$tmux_path" "$socket" \
    set-option -p -t "$pane_id" remain-on-exit on >/dev/null || {
    _fwdports_tmux_call "$tmux_path" "$socket" \
      kill-session -t "$session_id" 2>/dev/null || true
    return 1
  }
  printf '%s\t%s\n' "$session_id" "$pane_id"
}

fwdports_tmux_abort_created_session() {
  local tmux_path=$1 socket=$2 session_id=$3 nonce=$4 recorded_nonce

  [[ $session_id =~ ^\$[0-9]+$ &&
    $nonce =~ ^generation\.[A-Za-z0-9]+$ ]] || return 1
  if ! _fwdports_tmux_call "$tmux_path" "$socket" has-session \
    -t "$session_id" 2>/dev/null; then
    return 0
  fi
  recorded_nonce=$(_fwdports_tmux_call "$tmux_path" "$socket" \
    show-environment -t "$session_id" FWDPORTS_GENERATION 2>/dev/null) ||
    return 1
  [[ $recorded_nonce == "FWDPORTS_GENERATION=$nonce" ]] || {
    printf 'fwdports: refusing to abort a tmux session with another nonce\n' \
      >&2
    return 1
  }
  # This helper is only for the narrow gap after `new-session` returned its
  # exact ID but before durable pane evidence could be written.  Past that
  # point normal cleanup requires the stronger process evidence path.
  _fwdports_tmux_call "$tmux_path" "$socket" kill-session -t "$session_id"
}

fwdports_tmux_split_pane() {
  local tmux_path=$1 socket=$2 session_id=$3 nonce=$4 start_directory=$5
  local recorded_nonce pane_id recorded_session
  shift 5

  [[ $session_id =~ ^\$[0-9]+$ &&
    $nonce =~ ^generation\.[A-Za-z0-9]+$ && $# -gt 0 ]] || return 1
  recorded_nonce=$(_fwdports_tmux_call "$tmux_path" "$socket" \
    show-environment -t "$session_id" FWDPORTS_GENERATION) || return 1
  [[ $recorded_nonce == "FWDPORTS_GENERATION=$nonce" ]] || {
    printf 'fwdports: tmux session nonce changed before pane creation\n' >&2
    return 1
  }
  pane_id=$(_fwdports_tmux_call "$tmux_path" "$socket" split-window \
    -d -P -F '#{pane_id}' -t "$session_id" -c "$start_directory" -- \
    "$@") || return 1
  [[ $pane_id =~ ^%[0-9]+$ ]] || return 1
  recorded_session=$(_fwdports_tmux_call "$tmux_path" "$socket" \
    display-message -p -t "$pane_id" '#{session_id}') || return 1
  [[ $recorded_session == "$session_id" ]] || return 1
  _fwdports_tmux_call "$tmux_path" "$socket" set-option -p \
    -t "$pane_id" remain-on-exit on >/dev/null || return 1
  printf '%s\n' "$pane_id"
}

_fwdports_process_snapshot() {
  local pid=$1 line observed_pid parent_pid pgid sid tty stat extra

  [[ $pid =~ ^[0-9]+$ ]] || return 1
  # Request named columns rather than parsing the platform's default `ps`
  # layout. GNU and BSD ps both accept these fields; LC_ALL=C keeps tty and
  # state tokens stable enough for the on-disk evidence grammar.
  # Darwin calls the session column `sess`; procps accepts that spelling too.
  # Using `sid` works on GNU/Linux but makes every macOS pane unverifiable.
  line=$(LC_ALL=C ps -o pid= -o ppid= -o pgid= -o sess= -o tty= -o stat= \
    -p "$pid" 2>/dev/null) || return 1
  read -r observed_pid parent_pid pgid sid tty stat extra <<<"$line"
  [[ -z $extra && $observed_pid == "$pid" &&
    $parent_pid =~ ^[0-9]+$ && $pgid =~ ^[0-9]+$ &&
    $sid =~ ^[0-9]+$ && -n $tty && -n $stat ]] || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$parent_pid" "$pgid" "$sid" "$tty" "$stat"
}

_fwdports_tmux_pane_snapshot() {
  local tmux_path=$1 socket=$2 pane_id=$3

  _fwdports_tmux_call "$tmux_path" "$socket" display-message -p \
    -t "$pane_id" \
    $'#{session_id}\t#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{pane_dead}'
}

fwdports_tmux_record_pane() {
  local tmux_path=$1 socket=$2 expected_session=$3 expected_pane=$4
  local generation=$5 expected_digest=$6 output=$7 nonce relative parent
  local tmux_before tmux_after session_id pane_id pane_pid pane_tty pane_dead
  local process_record parent_pid pgid sid process_tty process_stat
  local leader_start recorded_nonce actual_digest manifest_before manifest_after
  local old_umask tmp

  nonce=${generation##*/}
  [[ $expected_session =~ ^\$[0-9]+$ &&
    $expected_pane =~ ^%[0-9]+$ ]] || {
    printf 'fwdports: tmux pane identifiers are invalid\n' >&2
    return 1
  }
  if [[ $output == "$generation/controller.pane" ]]; then
    relative=controller.pane
  else
    relative=${output#"$generation/legs/"}
    [[ $output == "$generation/legs/$relative" &&
      $relative =~ ^[A-Za-z][A-Za-z0-9_-]*/pane$ ]] || {
      printf 'fwdports: pane evidence path escapes its generation\n' >&2
      return 1
    }
  fi
  parent=${output%/*}
  [[ -d "$parent" && ! -L "$parent" ]] || {
    printf 'fwdports: pane evidence parent is unavailable\n' >&2
    return 1
  }
  _fwdports_runtime_validate_node "$parent" 'pane evidence parent' ||
    return 1
  actual_digest=$(fwdports_generation_manifest_digest "$generation") ||
    return 1
  [[ $actual_digest == "$expected_digest" ]] || {
    printf 'fwdports: generation changed before pane observation\n' >&2
    return 1
  }
  manifest_before=$(_fwdports_runtime_identity "$generation/manifest") ||
    return 1

  recorded_nonce=$(_fwdports_tmux_call "$tmux_path" "$socket" \
    show-environment -t "$expected_session" FWDPORTS_GENERATION) || return 1
  [[ $recorded_nonce == "FWDPORTS_GENERATION=$nonce" ]] || {
    printf 'fwdports: tmux session nonce does not match generation\n' >&2
    return 1
  }
  tmux_before=$(_fwdports_tmux_pane_snapshot "$tmux_path" "$socket" \
    "$expected_pane") || return 1
  IFS=$'\t' read -r session_id pane_id pane_pid pane_tty pane_dead \
    <<<"$tmux_before"
  [[ $session_id == "$expected_session" && $pane_id == "$expected_pane" &&
    $pane_pid =~ ^[0-9]+$ && $pane_tty == /dev/* &&
    $pane_dead == 0 ]] || {
    printf 'fwdports: live tmux pane relationship is invalid\n' >&2
    return 1
  }

  process_record=$(_fwdports_process_snapshot "$pane_pid") || {
    printf 'fwdports: cannot inspect tmux pane leader\n' >&2
    return 1
  }
  IFS=$'\t' read -r parent_pid pgid sid process_tty process_stat \
    <<<"$process_record"
  leader_start=$(_fwdports_process_start_identity "$pane_pid") || return 1
  process_tty=${process_tty#/dev/}
  [[ ${pane_tty#/dev/} == "$process_tty" ]] || {
    printf 'fwdports: tmux pane terminal does not match its leader\n' >&2
    return 1
  }

  # A second tmux snapshot detects pane replacement while `ps` was sampled.
  # PID reuse alone is insufficient ownership proof; the start identity below
  # binds the recorded PID to this exact process lifetime.
  tmux_after=$(_fwdports_tmux_pane_snapshot "$tmux_path" "$socket" \
    "$expected_pane") || return 1
  [[ $tmux_after == "$tmux_before" ]] || {
    printf 'fwdports: tmux pane changed while being observed\n' >&2
    return 1
  }
  actual_digest=$(fwdports_generation_manifest_digest "$generation") ||
    return 1
  manifest_after=$(_fwdports_runtime_identity "$generation/manifest") ||
    return 1
  [[ $actual_digest == "$expected_digest" &&
    $manifest_after == "$manifest_before" ]] || {
    printf 'fwdports: generation changed during pane observation\n' >&2
    return 1
  }

  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$parent/.pane.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! {
    printf 'version\t1\n'
    printf 'generation\t%s\n' "$nonce"
    printf 'manifest-digest\t%s\n' "$expected_digest"
    printf 'session-id\t%s\n' "$expected_session"
    printf 'pane-id\t%s\n' "$expected_pane"
    printf 'leader-pid\t%s\n' "$pane_pid"
    printf 'leader-start\t%s\n' "$leader_start"
    printf 'tty\t%s\n' "$pane_tty"
    printf 'sid\t%s\n' "$sid"
    printf 'pgid\t%s\n' "$pgid"
    printf 'parent-pid\t%s\n' "$parent_pid"
    printf 'process-state\t%s\n' "$process_stat"
  } >"$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    return 1
  fi
}

_fwdports_pane_evidence_read() {
  local generation=$1 expected_digest=$2 evidence=$3 line key value extra
  local line_number=0 identity_before identity_after
  local version='' nonce='' digest='' session_id='' pane_id='' leader_pid=''
  local leader_start='' tty='' sid='' pgid='' parent_pid='' process_state=''

  [[ ($evidence == "$generation"/legs/*/pane ||
    $evidence == "$generation/controller.pane") &&
    -f "$evidence" && ! -L "$evidence" ]] || {
    printf 'fwdports: pane evidence is unavailable\n' >&2
    return 2
  }
  _fwdports_runtime_validate_node "$evidence" 'pane evidence' || return 2
  identity_before=$(_fwdports_runtime_identity "$evidence") || return 2
  while IFS= read -r line || [[ -n $line ]]; do
    line_number=$((line_number + 1))
    IFS=$'\t' read -r key value extra <<<"$line"
    [[ -n $key && -n $value && -z $extra ]] || return 2
    case "$line_number:$key" in
      1:version) version=$value ;;
      2:generation) nonce=$value ;;
      3:manifest-digest) digest=$value ;;
      4:session-id) session_id=$value ;;
      5:pane-id) pane_id=$value ;;
      6:leader-pid) leader_pid=$value ;;
      7:leader-start) leader_start=$value ;;
      8:tty) tty=$value ;;
      9:sid) sid=$value ;;
      10:pgid) pgid=$value ;;
      11:parent-pid) parent_pid=$value ;;
      12:process-state) process_state=$value ;;
      *) return 2 ;;
    esac
  done <"$evidence"
  identity_after=$(_fwdports_runtime_identity "$evidence") || return 2
  [[ $identity_before == "$identity_after" && $line_number -eq 12 &&
    $version == 1 && $nonce == "${generation##*/}" &&
    $digest == "$expected_digest" && $session_id =~ ^\$[0-9]+$ &&
    $pane_id =~ ^%[0-9]+$ && $leader_pid =~ ^[0-9]+$ &&
    $tty == /dev/* && $sid =~ ^[0-9]+$ && $pgid =~ ^[0-9]+$ &&
    $parent_pid =~ ^[0-9]+$ && -n $leader_start &&
    -n $process_state ]] || {
    printf 'fwdports: pane evidence binding is invalid\n' >&2
    return 2
  }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session_id" "$pane_id" "$leader_pid" "$leader_start" "$tty" \
    "$sid" "$pgid" "$parent_pid" "$process_state"
}

fwdports_tmux_verify_pane() {
  local tmux_path=$1 socket=$2 generation=$3 expected_digest=$4 evidence=$5
  local record expected_session expected_pane expected_pid expected_start
  local expected_tty expected_sid expected_pgid expected_parent expected_state
  local nonce recorded_nonce tmux_record session_id pane_id pane_pid pane_tty
  local pane_dead process_record parent_pid pgid sid process_tty process_state
  local current_start

  record=$(_fwdports_pane_evidence_read "$generation" "$expected_digest" \
    "$evidence") || return $?
  IFS=$'\t' read -r expected_session expected_pane expected_pid \
    expected_start expected_tty expected_sid expected_pgid expected_parent \
    expected_state <<<"$record"
  nonce=${generation##*/}

  # An absent private server/session/pane is ordinary liveness failure, not an
  # ownership violation. Existing but mismatched evidence is different: it is
  # retained and reported so status never turns ambiguity into signal rights.
  _fwdports_tmux_call "$tmux_path" "$socket" has-session \
    -t "$expected_session" 2>/dev/null || return 1
  recorded_nonce=$(_fwdports_tmux_call "$tmux_path" "$socket" \
    show-environment -t "$expected_session" FWDPORTS_GENERATION \
    2>/dev/null) || return 2
  [[ $recorded_nonce == "FWDPORTS_GENERATION=$nonce" ]] || {
    printf 'fwdports: tmux session nonce changed\n' >&2
    return 2
  }
  tmux_record=$(_fwdports_tmux_pane_snapshot "$tmux_path" "$socket" \
    "$expected_pane" 2>/dev/null) || return 1
  IFS=$'\t' read -r session_id pane_id pane_pid pane_tty pane_dead \
    <<<"$tmux_record"
  [[ $session_id == "$expected_session" && $pane_id == "$expected_pane" &&
    $pane_pid == "$expected_pid" && $pane_tty == "$expected_tty" &&
    $pane_dead == 0 ]] || {
    # A pane retained by remain-on-exit is conclusively down. Other identity
    # mismatches are ambiguous and therefore fail closed.
    [[ $session_id == "$expected_session" && $pane_id == "$expected_pane" &&
      $pane_dead == 1 ]] && return 1
    printf 'fwdports: tmux pane identity changed\n' >&2
    return 2
  }
  # tmux just proved this exact pane live. Failure to inspect its process is
  # therefore missing ownership evidence, not proof that the pane is dead.
  process_record=$(_fwdports_process_snapshot "$expected_pid") || return 2
  IFS=$'\t' read -r parent_pid pgid sid process_tty process_state \
    <<<"$process_record"
  current_start=$(_fwdports_process_start_identity "$expected_pid") || return 2
  process_tty=${process_tty#/dev/}
  if [[ $current_start != "$expected_start" ||
    ${expected_tty#/dev/} != "$process_tty" ||
    $sid != "$expected_sid" || $pgid != "$expected_pgid" ||
    $parent_pid != "$expected_parent" ]]; then
    printf 'fwdports: pane process ownership evidence changed\n' >&2
    return 2
  fi
  : "$expected_state" "$process_state"
  return 0
}

fwdports_tmux_session_named_exists() {
  local tmux_path=$1 socket=$2 session_name=$3
  _fwdports_tmux_call "$tmux_path" "$socket" has-session \
    -t "$session_name" 2>/dev/null
}

_fwdports_process_group_records() {
  local wanted_pgid=$1 output line pid pgid sid tty state extra found=0
  local records=''

  [[ $wanted_pgid =~ ^[0-9]+$ ]] || return 1
  output=$(LC_ALL=C ps -e -o pid= -o pgid= -o sess= -o tty= -o stat= \
    2>/dev/null) || return 2
  [[ -n $output ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    read -r pid pgid sid tty state extra <<<"$line"
    [[ -z $extra && $pid =~ ^[0-9]+$ && $pgid =~ ^[0-9]+$ &&
      $sid =~ ^[0-9]+$ && -n $tty && -n $state ]] || return 2
    [[ $pgid == "$wanted_pgid" ]] || continue
    records=$records$pid$'\t'$sid$'\t'$tty$'\t'$state$'\n'
    found=1
  done <<<"$output"
  [[ $found -eq 1 ]] || return 1
  printf '%s' "$records"
}

_fwdports_verify_owned_group() {
  local generation=$1 digest=$2 evidence=$3 record session pane leader
  local leader_start expected_tty expected_sid expected_pgid parent state
  local members line pid sid tty process_state extra leader_found=0
  local current_start

  record=$(_fwdports_pane_evidence_read "$generation" "$digest" \
    "$evidence") || return 2
  IFS=$'\t' read -r session pane leader leader_start expected_tty \
    expected_sid expected_pgid parent state <<<"$record"
  current_start=$(_fwdports_process_start_identity "$leader") || {
    printf 'fwdports: recorded leader is no longer live\n' >&2
    return 2
  }
  [[ $current_start == "$leader_start" ]] || {
    printf 'fwdports: recorded leader process identity changed\n' >&2
    return 2
  }
  members=$(_fwdports_process_group_records "$expected_pgid") || {
    printf 'fwdports: recorded process group is no longer live\n' >&2
    return 2
  }
  while IFS= read -r line || [[ -n $line ]]; do
    IFS=$'\t' read -r pid sid tty process_state extra <<<"$line"
    [[ -z $extra && $sid == "$expected_sid" &&
      ${tty#/dev/} == "${expected_tty#/dev/}" ]] || {
      printf 'fwdports: process group contains an unverifiable member\n' >&2
      return 2
    }
    [[ $pid == "$leader" ]] && leader_found=1
    : "$process_state"
  done <<<"$members"
  [[ $leader_found -eq 1 ]] || {
    printf 'fwdports: recorded leader is absent from its process group\n' >&2
    return 2
  }
  : "$session" "$pane" "$parent" "$state"
  printf '%s\n' "$expected_pgid"
}

_fwdports_lifecycle_allows_stop() {
  local root=$1 pointer_kind=$2 generation=$3 digest=$4 pointer control_record
  local phase desired

  pointer=$(fwdports_pointer_read "$root" "$pointer_kind") || return 1
  [[ $pointer == "$generation"$'\t'"$digest" ]] || return 1
  control_record=$(fwdports_control_read "$generation" "$digest") || return 1
  IFS=$'\t' read -r phase desired _ _ _ <<<"$control_record"
  [[ $phase == stopping && $desired == stopped ]]
}

_fwdports_wait_group_empty() {
  local pgid=$1 attempts=$2 delay=$3 index=0 status

  while :; do
    if _fwdports_process_group_records "$pgid" >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    case "$status" in
      0)
        [[ $index -lt $attempts ]] || return 1
        sleep "$delay"
        index=$((index + 1))
        ;;
      1) return 0 ;;
      *) return 2 ;;
    esac
  done
}

fwdports_tmux_terminate_pane() {
  local tmux_path=$1 socket=$2 root=$3 pointer_kind=$4 generation=$5
  local digest=$6 evidence=$7 attempts=$8 delay=$9 verify_status pgid

  [[ $attempts =~ ^[1-9][0-9]*$ &&
    $delay =~ ^(0|0\.[0-9]+|[1-9][0-9]*(\.[0-9]+)?)$ ]] || {
    printf 'fwdports: invalid process termination bound\n' >&2
    return 1
  }
  _fwdports_lifecycle_allows_stop "$root" "$pointer_kind" \
    "$generation" "$digest" || {
    printf 'fwdports: generation no longer authorizes cleanup\n' >&2
    return 74
  }
  if fwdports_tmux_verify_pane "$tmux_path" "$socket" "$generation" \
    "$digest" "$evidence"; then
    verify_status=0
  else
    verify_status=$?
  fi
  if [[ $verify_status -ne 0 ]]; then
    # Even a conclusively dead tmux pane is not permission to signal a
    # survivor found by stale PID/PGID evidence. Retain it for diagnosis.
    printf 'fwdports: recorded leader is no longer live\n' >&2
    return 74
  fi
  pgid=$(_fwdports_verify_owned_group "$generation" "$digest" "$evidence") ||
    return 74
  _fwdports_lifecycle_allows_stop "$root" "$pointer_kind" \
    "$generation" "$digest" || return 74

  # Bash's kill builtin accepts a negative process-group ID as one argument;
  # `--` prevents that negative number from being parsed as another option.
  kill -TERM -- "-$pgid" 2>/dev/null || {
    _fwdports_wait_group_empty "$pgid" 1 "$delay" && {
      printf 'term\n'
      return 0
    }
    printf 'fwdports: TERM could not be delivered to owned process group\n' >&2
    return 74
  }
  if _fwdports_wait_group_empty "$pgid" "$attempts" "$delay"; then
    printf 'term\n'
    return 0
  fi

  # Escalation gets the same complete authentication as TERM. In particular,
  # if the leader exited but left an apparent same-PGID process behind, core
  # refuses to guess that the survivor is still ours.
  _fwdports_lifecycle_allows_stop "$root" "$pointer_kind" \
    "$generation" "$digest" || return 74
  fwdports_tmux_verify_pane "$tmux_path" "$socket" "$generation" \
    "$digest" "$evidence" || {
    printf 'fwdports: pane ownership changed before KILL\n' >&2
    return 74
  }
  pgid=$(_fwdports_verify_owned_group "$generation" "$digest" "$evidence") ||
    return 74
  kill -KILL -- "-$pgid" 2>/dev/null || true
  if ! _fwdports_wait_group_empty "$pgid" "$attempts" "$delay"; then
    printf 'fwdports: owned process group remains after KILL\n' >&2
    return 74
  fi
  printf 'kill\n'
}

fwdports_tmux_remove_generation_session() {
  local tmux_path=$1 socket=$2 generation=$3 digest=$4 session_name=$5
  local evidence record evidence_session evidence_pane session_id=''
  local known_panes='|' recorded_nonce pane panes

  for evidence in "$generation"/legs/*/pane \
    "$generation"/controller.pane; do
    [[ -e "$evidence" || -L "$evidence" ]] || continue
    record=$(_fwdports_pane_evidence_read "$generation" "$digest" \
      "$evidence") || return 74
    IFS=$'\t' read -r evidence_session evidence_pane _ _ _ _ _ _ _ \
      <<<"$record"
    if [[ -n $session_id && $evidence_session != "$session_id" ]]; then
      printf 'fwdports: generation evidence spans multiple tmux sessions\n' >&2
      return 74
    fi
    session_id=$evidence_session
    known_panes=$known_panes$evidence_pane'|'
  done
  # No recorded pane means no tmux authority. This is normal for a crash
  # before session creation; a same-name user session, if any, stays untouched.
  [[ -n $session_id ]] || return 0
  if ! _fwdports_tmux_call "$tmux_path" "$socket" has-session \
    -t "$session_id" 2>/dev/null; then
    return 0
  fi
  recorded_nonce=$(_fwdports_tmux_call "$tmux_path" "$socket" \
    show-environment -t "$session_id" FWDPORTS_GENERATION 2>/dev/null) ||
    return 74
  [[ $recorded_nonce == "FWDPORTS_GENERATION=${generation##*/}" ]] || {
    printf 'fwdports: refusing to remove a tmux session with another nonce\n' \
      >&2
    return 74
  }
  panes=$(_fwdports_tmux_call "$tmux_path" "$socket" list-panes -s \
    -t "$session_id" -F '#{pane_id}') || {
    printf 'fwdports: cannot enumerate tmux panes before removal\n' >&2
    return 74
  }
  [[ -n $panes ]] || {
    printf 'fwdports: tmux returned no panes for a live session\n' >&2
    return 74
  }
  while IFS= read -r pane || [[ -n $pane ]]; do
    [[ -n $pane ]] || continue
    [[ $pane =~ ^%[0-9]+$ ]] || {
      printf 'fwdports: tmux returned a malformed pane identifier\n' >&2
      return 74
    }
    case "$known_panes" in
      *"|$pane|"*) ;;
      *)
        printf 'fwdports: tmux session contains an unrecorded pane\n' >&2
        return 74
        ;;
    esac
  done <<<"$panes"
  # The exact server socket, session ID, and nonce—not the friendly name—are
  # the authority for this destructive operation.
  _fwdports_tmux_call "$tmux_path" "$socket" kill-session -t "$session_id"
  : "$session_name"
}
