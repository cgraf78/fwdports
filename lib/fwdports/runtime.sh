#!/usr/bin/env bash
# Runtime state and ownership primitives. Every destructive operation in this
# module is rooted beneath a validated per-user directory and requires an
# independently rechecked generation identity before it acts.

_fwdports_runtime_trust_record() {
  local owner=$1 mode=$2 effective_uid
  effective_uid=$(id -u) || return 1
  if [[ $owner != 0 && $owner != "$effective_uid" ]]; then
    printf 'fwdports: path has an untrusted owner\n' >&2
    return 1
  fi
  [[ $mode =~ ^[0-7]{3,4}$ ]] || {
    printf 'fwdports: path mode is invalid\n' >&2
    return 1
  }
  if (((8#$mode & 022) != 0)); then
    printf 'fwdports: path is writable by an untrusted group or identity\n' >&2
    return 1
  fi
}

_fwdports_runtime_owner_mode() {
  local path=$1 output
  if output=$(LC_ALL=C stat -c '%u %a' -- "$path" 2>/dev/null); then
    printf '%s\n' "$output"
    return 0
  fi
  if output=$(LC_ALL=C stat -f '%u %Lp' "$path" 2>/dev/null); then
    printf '%s\n' "$output"
    return 0
  fi
  return 1
}

_fwdports_runtime_identity() {
  local path=$1 output
  if output=$(LC_ALL=C stat -c '%u:%a:%d:%i:%s:%Y' -- "$path" \
    2>/dev/null); then
    printf '%s\n' "$output"
    return 0
  fi
  if output=$(LC_ALL=C stat -f '%u:%Lp:%d:%i:%z:%m' "$path" \
    2>/dev/null); then
    printf '%s\n' "$output"
    return 0
  fi
  return 1
}

_fwdports_runtime_validate_node() {
  local path=$1 role=$2 owner mode
  read -r owner mode <<<"$(_fwdports_runtime_owner_mode "$path")" || {
    printf 'fwdports: cannot inspect %s: %s\n' "$role" "$path" >&2
    return 1
  }
  if ! _fwdports_runtime_trust_record "$owner" "$mode" >/dev/null 2>&1; then
    printf 'fwdports: untrusted %s: %s\n' "$role" "$path" >&2
    return 1
  fi
}

_fwdports_runtime_validate_parents() {
  local path=$1 anchor=$2 parent relative current component old_ifs
  local -a components=()

  parent=${path%/*}
  [[ $parent != "$path" ]] || parent=/
  case "$parent" in
    "$anchor" | "$anchor"/*) ;;
    *)
      printf 'fwdports: path escapes trusted parent: %s\n' "$path" >&2
      return 1
      ;;
  esac
  [[ -d "$anchor" && ! -L "$anchor" ]] || {
    printf 'fwdports: trusted parent is not a regular directory: %s\n' \
      "$anchor" >&2
    return 1
  }
  _fwdports_runtime_validate_node "$anchor" parent || return 1
  [[ $parent != "$anchor" ]] || return 0

  relative=${parent#"$anchor"/}
  old_ifs=$IFS
  IFS=/ read -r -a components <<<"$relative"
  IFS=$old_ifs
  current=$anchor
  for component in "${components[@]}"; do
    [[ -n $component && $component != . && $component != .. ]] || {
      printf 'fwdports: path has an unsafe parent component\n' >&2
      return 1
    }
    current=$current/$component
    [[ -d "$current" && ! -L "$current" ]] || {
      printf 'fwdports: untrusted parent type: %s\n' "$current" >&2
      return 1
    }
    _fwdports_runtime_validate_node "$current" parent || return 1
  done
}

fwdports_validate_trusted_path() {
  local path=$1 kind=$2 anchor=$3 allowed_target_root=${4:-$3}
  local canonical_anchor canonical_allowed parent target combined
  local canonical_target owner mode

  case "$path" in
    '' | / | *$'\n'* | *$'\r'* | *$'\t'* | *//* | */./* | */. | */../* | */..)
      printf 'fwdports: path is not a normalized absolute path\n' >&2
      return 1
      ;;
    /*) ;;
    *)
      printf 'fwdports: path is not absolute\n' >&2
      return 1
      ;;
  esac
  canonical_anchor=$(cd -P -- "$anchor" 2>/dev/null && pwd -P) || {
    printf 'fwdports: cannot resolve trusted parent: %s\n' "$anchor" >&2
    return 1
  }
  canonical_allowed=$(cd -P -- "$allowed_target_root" 2>/dev/null && pwd -P) || {
    printf 'fwdports: cannot resolve allowed target root\n' >&2
    return 1
  }
  _fwdports_runtime_validate_parents "$path" "$canonical_anchor" || return 1

  if [[ -L "$path" ]]; then
    read -r owner mode <<<"$(_fwdports_runtime_owner_mode "$path")" || {
      printf 'fwdports: cannot inspect symbolic link\n' >&2
      return 1
    }
    # Symlink mode bits are not portable and are commonly reported as 0777;
    # link ownership and the separately validated target carry the trust.
    if [[ $owner != 0 && $owner != "$(id -u)" ]]; then
      printf 'fwdports: symbolic link has an untrusted owner\n' >&2
      return 1
    fi
    target=$(readlink "$path") || return 1
    parent=${path%/*}
    case "$target" in
      /*) combined=$target ;;
      *) combined=$parent/$target ;;
    esac
    parent=$(cd -P -- "${combined%/*}" 2>/dev/null && pwd -P) || {
      printf 'fwdports: symbolic-link target parent is unavailable\n' >&2
      return 1
    }
    canonical_target=$parent/${combined##*/}
    case "$canonical_target" in
      "$canonical_allowed"/*) ;;
      *)
        printf 'fwdports: symbolic-link target escapes allowed root\n' >&2
        return 1
        ;;
    esac
    [[ ! -L "$canonical_target" ]] || {
      printf 'fwdports: symbolic-link target must not be another link\n' >&2
      return 1
    }
    fwdports_validate_trusted_path "$canonical_target" "$kind" \
      "$canonical_allowed" "$canonical_allowed"
    return $?
  fi

  case "$kind" in
    file) [[ -f "$path" ]] ;;
    executable) [[ -f "$path" && -x "$path" ]] ;;
    directory) [[ -d "$path" ]] ;;
    *)
      printf 'fwdports: internal unknown trusted-path kind: %s\n' "$kind" >&2
      return 1
      ;;
  esac || {
    printf 'fwdports: trusted path has the wrong type: %s\n' "$path" >&2
    return 1
  }
  _fwdports_runtime_validate_node "$path" path || return 1
  printf '%s\n' "$path"
}

fwdports_snapshot_trusted_file() {
  local source=$1 destination=$2 anchor=$3 kind=${4:-executable}
  local allowed_target_root=${5:-$anchor}
  local canonical_before canonical_after identity_before identity_after
  local destination_parent old_umask tmp

  canonical_before=$(fwdports_validate_trusted_path "$source" "$kind" \
    "$anchor" "$allowed_target_root") || return 1
  identity_before=$(_fwdports_runtime_identity "$canonical_before") || {
    printf 'fwdports: cannot identify source before copy\n' >&2
    return 1
  }
  destination_parent=${destination%/*}
  [[ $destination_parent != "$destination" &&
    -d "$destination_parent" && ! -L "$destination_parent" ]] || {
    printf 'fwdports: snapshot parent is unavailable\n' >&2
    return 1
  }
  _fwdports_runtime_validate_node "$destination_parent" \
    'snapshot parent' || return 1

  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$destination_parent/.fwdports.snapshot.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! cp "$canonical_before" "$tmp"; then
    rm -f -- "$tmp"
    printf 'fwdports: cannot copy trusted source\n' >&2
    return 1
  fi
  case "$kind" in
    executable) chmod 0700 "$tmp" ;;
    file) chmod 0600 "$tmp" ;;
    *)
      rm -f -- "$tmp"
      printf 'fwdports: unsupported snapshot kind\n' >&2
      return 1
      ;;
  esac || {
    rm -f -- "$tmp"
    return 1
  }

  canonical_after=$(fwdports_validate_trusted_path "$source" "$kind" \
    "$anchor" "$allowed_target_root") || {
    rm -f -- "$tmp"
    return 1
  }
  identity_after=$(_fwdports_runtime_identity "$canonical_after") || {
    rm -f -- "$tmp"
    return 1
  }
  if [[ $canonical_before != "$canonical_after" ||
    $identity_before != "$identity_after" ]]; then
    rm -f -- "$tmp"
    printf 'fwdports: trusted source changed while being copied\n' >&2
    return 1
  fi
  if ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
}

_fwdports_process_start_identity() {
  local pid=$1 stat_line rest ps_start old_ifs
  local -a fields=()

  if [[ -r /proc/$pid/stat ]]; then
    IFS= read -r stat_line </proc/"$pid"/stat || return 1
    rest=${stat_line##*) }
    # After the parenthesized command name, field 3 is first; process start
    # time is field 22 and therefore positional field 20 in this remainder.
    old_ifs=$IFS
    IFS=' ' read -r -a fields <<<"$rest"
    IFS=$old_ifs
    [[ ${#fields[@]} -ge 20 && ${fields[19]} =~ ^[0-9]+$ ]] || return 1
    printf 'linux:%s\n' "${fields[19]}"
    return 0
  fi
  ps_start=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
  ps_start=${ps_start#"${ps_start%%[![:space:]]*}"}
  ps_start=${ps_start%"${ps_start##*[![:space:]]}"}
  [[ -n $ps_start ]] || return 1
  printf 'bsd:%s\n' "$ps_start"
}

_fwdports_lock_read_owner() {
  local file=$1 kind value rest
  local version='' nonce='' uid='' pid='' start='' target=''

  [[ -f "$file" && ! -L "$file" ]] || return 2
  while IFS=$'\t' read -r kind value rest || [[ -n ${kind:-} ]]; do
    [[ -n $kind && -n $value && -z $rest ]] || return 2
    case "$kind" in
      version)
        [[ -z $version ]] || return 2
        version=$value
        ;;
      nonce)
        [[ -z $nonce ]] || return 2
        nonce=$value
        ;;
      uid)
        [[ -z $uid ]] || return 2
        uid=$value
        ;;
      pid)
        [[ -z $pid ]] || return 2
        pid=$value
        ;;
      start)
        [[ -z $start ]] || return 2
        start=$value
        ;;
      target)
        [[ -z $target ]] || return 2
        target=$value
        ;;
      *) return 2 ;;
    esac
  done <"$file"
  [[ $version == 1 && $nonce =~ ^(candidate|reclaim)\.[A-Za-z0-9]+$ &&
    $uid =~ ^[0-9]+$ && $pid =~ ^[0-9]+$ && -n $start ]] || return 2
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$nonce" "$uid" "$pid" "$start" "$target"
}

_fwdports_lock_owner_state() {
  local file=$1 record nonce uid pid recorded_start target current_start

  record=$(_fwdports_lock_read_owner "$file") || return 2
  IFS=$'\t' read -r nonce uid pid recorded_start target <<<"$record"
  [[ $uid == "$(id -u)" ]] || return 2
  if kill -0 "$pid" 2>/dev/null; then
    current_start=$(_fwdports_process_start_identity "$pid") || return 2
    [[ $current_start == "$recorded_start" ]] && return 0
  fi
  return 1
}

_fwdports_lock_write_owner() {
  local path=$1 nonce=$2 target=${3:-} start
  start=$(_fwdports_process_start_identity "$$") || return 1
  if ! {
    printf 'version\t1\n'
    printf 'nonce\t%s\n' "$nonce"
    printf 'uid\t%s\n' "$(id -u)"
    printf 'pid\t%s\n' "$$"
    printf 'start\t%s\n' "$start"
    [[ -z $target ]] || printf 'target\t%s\n' "$target"
  } >"$path" || ! chmod 0600 "$path"; then
    return 1
  fi
}

_fwdports_lock_validate_candidates() {
  local root=$1 candidates

  candidates=$root/lock-candidates
  [[ -d "$root" && ! -L "$root" &&
    -d "$candidates" && ! -L "$candidates" ]] || return 1
  _fwdports_runtime_validate_node "$root" 'runtime root' \
    >/dev/null 2>&1 || return 1
  _fwdports_runtime_validate_node "$candidates" 'lock candidate directory' \
    >/dev/null 2>&1 || return 1
}

_fwdports_lock_prepare_candidates() {
  local root=$1 candidates old_umask

  candidates=$root/lock-candidates
  if [[ ! -e "$candidates" && ! -L "$candidates" ]]; then
    old_umask=$(umask)
    umask 077
    if ! mkdir "$candidates" 2>/dev/null; then
      umask "$old_umask"
      # A cooperating contender may have won the mkdir race. The validation
      # below decides whether that path is the expected private directory.
      [[ -d "$candidates" && ! -L "$candidates" ]] || return 1
    else
      umask "$old_umask"
    fi
  fi
  _fwdports_lock_validate_candidates "$root"
}

_fwdports_lock_read_pointer() {
  local pointer=$1 raw read_status

  # Command substitution normally strips every trailing newline, which would
  # make a hostile newline-bearing symlink target indistinguishable from a
  # valid target. Append a sentinel, remove readlink's one output delimiter,
  # and only then reject any newline that was part of the raw target.
  raw=$(
    readlink "$pointer"
    read_status=$?
    printf '\001'
    exit "$read_status"
  ) || return 2
  [[ $raw == *$'\001' ]] || return 2
  raw=${raw%$'\001'}
  [[ $raw == *$'\n' ]] || return 2
  raw=${raw%$'\n'}
  [[ -n $raw && $raw != *$'\n'* && $raw != *$'\r'* &&
    $raw != *$'\t'* && $raw != *$'\001'* ]] || return 2
  printf '%s\n' "$raw"
}

_fwdports_lock_candidate_for() {
  local root owner_file expected_kind pointer_target pointer_after
  local record nonce uid pid start target candidate

  root=$1
  owner_file=$2
  case "$owner_file" in
    "$root/lifecycle.lock") expected_kind=candidate ;;
    "$root/reclaim.lock") expected_kind=reclaim ;;
    *) return 2 ;;
  esac

  # Android app filesystems can forbid hard links while still providing the
  # atomic symlink creation POSIX shells need.  Accept only a one-component,
  # relative pointer into our private candidate directory; absolute paths and
  # traversal never become input to filesystem operations.
  _fwdports_lock_validate_candidates "$root" || return 2
  [[ -L "$owner_file" ]] || return 2
  pointer_target=$(_fwdports_lock_read_pointer "$owner_file") || return 2
  case "$expected_kind:$pointer_target" in
    candidate:lock-candidates/candidate.* | \
      reclaim:lock-candidates/reclaim.*) ;;
    *) return 2 ;;
  esac
  [[ $pointer_target =~ ^lock-candidates/$expected_kind\.[A-Za-z0-9]+$ ]] ||
    return 2
  candidate=$root/$pointer_target
  [[ -f "$candidate" && ! -L "$candidate" ]] || return 2
  # Bind the parsed text back to the kernel-resolved directory entry. Besides
  # narrowing pointer races, this catches readlink implementations that render
  # a trailing target newline like their normal output delimiter: the actual
  # link remains dangling and therefore cannot be the candidate's inode.
  [[ "$owner_file" -ef "$candidate" ]] || return 2

  record=$(_fwdports_lock_read_owner "$candidate") || return 2
  IFS=$'\t' read -r nonce uid pid start target <<<"$record"
  [[ $nonce == "${candidate##*/}" ]] || return 2
  _fwdports_runtime_validate_node "$candidate" 'lock owner' \
    >/dev/null 2>&1 || return 2
  # Re-read after validating the candidate so a concurrent pointer change is
  # never mistaken for authority over the file we just inspected.
  pointer_after=$(_fwdports_lock_read_pointer "$owner_file") || return 2
  [[ $pointer_after == "$pointer_target" ]] || return 2
  printf '%s\n' "$candidate"
}

_fwdports_lock_publish() {
  local root=$1 candidate=$2 pointer=$3 kind target status current

  case "$pointer" in
    "$root/lifecycle.lock") kind=candidate ;;
    "$root/reclaim.lock") kind=reclaim ;;
    *) return 1 ;;
  esac
  [[ $candidate == "$root/lock-candidates/$kind."* &&
    -f "$candidate" && ! -L "$candidate" ]] || return 1
  _fwdports_lock_validate_candidates "$root" || return 1
  target=lock-candidates/${candidate##*/}
  # `-n` is supported by the GNU, BSD, BusyBox, and Termux implementations in
  # the compatibility matrix. It prevents a raced destination symlink to a
  # directory from absorbing a child link while falsely reporting success.
  if ln -s -n "$target" "$pointer" 2>/dev/null; then
    current=$(_fwdports_lock_candidate_for "$root" "$pointer") || return 74
    [[ $current == "$candidate" ]] || return 74
    return 0
  else
    status=$?
  fi
  # An extant path is ordinary contention. If no path was published, report a
  # filesystem capability failure instead of falsely claiming another live
  # owner holds the lock.
  [[ -e "$pointer" || -L "$pointer" ]] && return 75
  return "$status"
}

_fwdports_lock_unpublish() {
  local root=$1 pointer=$2 candidate=$3 current

  current=$(_fwdports_lock_candidate_for "$root" "$pointer") || return 1
  [[ $current == "$candidate" ]] || return 1
  rm -f -- "$pointer" || return 1
  rm -f -- "$candidate"
}

_fwdports_lock_gc_candidates() {
  local root=$1 candidates lock reclaim candidate state
  local lock_candidate='' reclaim_candidate=''

  # Assign dependent paths only after `root` is local. Bash dynamic scoping can
  # otherwise resolve `$root` from a caller while evaluating one `local`
  # command, which is especially dangerous for cleanup paths.
  candidates=$root/lock-candidates
  lock=$root/lifecycle.lock
  reclaim=$root/reclaim.lock

  if [[ -e "$lock" || -L "$lock" ]]; then
    lock_candidate=$(_fwdports_lock_candidate_for "$root" "$lock" \
      2>/dev/null) || lock_candidate=
  fi
  if [[ -e "$reclaim" || -L "$reclaim" ]]; then
    reclaim_candidate=$(_fwdports_lock_candidate_for "$root" "$reclaim" \
      2>/dev/null) || reclaim_candidate=
  fi

  for candidate in "$candidates"/candidate.* "$candidates"/reclaim.*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    [[ -f "$candidate" && ! -L "$candidate" ]] || continue
    if [[ $candidate == "$lock_candidate" ||
      $candidate == "$reclaim_candidate" ]]; then
      continue
    fi
    if _fwdports_lock_owner_state "$candidate"; then
      state=0
    else
      state=$?
    fi
    # A complete dead owner can no longer publish this candidate. Incomplete
    # or otherwise unverifiable records are retained; garbage collection must
    # not turn malformed evidence into deletion authority.
    [[ $state -eq 1 ]] && rm -f -- "$candidate"
  done
}

fwdports_lock_acquire() {
  local root=$1 candidates candidate lock nonce old_umask state
  local reclaim reclaim_candidate reclaim_nonce stale_candidate stale_nonce
  local current publish_status

  [[ -d "$root" && ! -L "$root" ]] || {
    printf 'fwdports: runtime root is unavailable\n' >&2
    return 1
  }
  _fwdports_runtime_validate_node "$root" 'runtime root' || return 1
  candidates=$root/lock-candidates
  lock=$root/lifecycle.lock
  reclaim=$root/reclaim.lock
  if ! _fwdports_lock_prepare_candidates "$root"; then
    printf 'fwdports: lock candidate directory is untrusted\n' >&2
    return 1
  fi

  # A crashed reclaimer leaves an owner-bearing record, never an ownerless
  # directory. Remove it only after proving its recorded process identity is
  # gone; the lifecycle lock itself is untouched during this cleanup.
  if [[ -e "$reclaim" || -L "$reclaim" ]]; then
    reclaim_candidate=$(_fwdports_lock_candidate_for "$root" "$reclaim") || {
      printf 'fwdports: reclaim lock ownership is invalid\n' >&2
      return 74
    }
    if _fwdports_lock_owner_state "$reclaim_candidate"; then
      state=0
    else
      state=$?
    fi
    case "$state" in
      0)
        printf 'fwdports: lifecycle recovery is already active\n' >&2
        return 75
        ;;
      1)
        _fwdports_lock_unpublish "$root" "$reclaim" \
          "$reclaim_candidate" || return 74
        ;;
      *)
        printf 'fwdports: reclaim lock owner cannot be verified\n' >&2
        return 74
        ;;
    esac
  fi

  stale_candidate=
  reclaim_candidate=
  if [[ -e "$lock" || -L "$lock" ]]; then
    stale_candidate=$(_fwdports_lock_candidate_for "$root" "$lock") || {
      printf 'fwdports: lifecycle lock ownership is invalid\n' >&2
      return 74
    }
    if _fwdports_lock_owner_state "$stale_candidate"; then
      state=0
    else
      state=$?
    fi
    case "$state" in
      0)
        printf 'fwdports: lifecycle operation is already locked\n' >&2
        return 75
        ;;
      1)
        stale_nonce=${stale_candidate##*/}
        old_umask=$(umask)
        umask 077
        reclaim_candidate=$(mktemp "$candidates/reclaim.XXXXXXXX") || {
          umask "$old_umask"
          return 1
        }
        umask "$old_umask"
        reclaim_nonce=${reclaim_candidate##*/}
        if ! _fwdports_lock_write_owner "$reclaim_candidate" \
          "$reclaim_nonce" "$stale_nonce"; then
          rm -f -- "$reclaim_candidate"
          return 1
        fi
        if _fwdports_lock_publish "$root" "$reclaim_candidate" \
          "$reclaim"; then
          publish_status=0
        else
          publish_status=$?
        fi
        if [[ $publish_status -ne 0 ]]; then
          if [[ $publish_status -eq 74 ]]; then
            printf 'fwdports: lifecycle recovery publication is invalid\n' \
              >&2
            return 74
          fi
          rm -f -- "$reclaim_candidate"
          if [[ $publish_status -eq 75 ]]; then
            printf 'fwdports: lifecycle recovery is already active\n' >&2
            return 75
          fi
          printf 'fwdports: cannot publish lifecycle recovery lock\n' >&2
          return 1
        fi
        # Holding a live reclaimer pointer prevents another contender from
        # entering the gap between stale-lock removal and the new pointer.
        current=$(_fwdports_lock_candidate_for "$root" "$lock") || current=
        if [[ $current != "$stale_candidate" ]]; then
          _fwdports_lock_unpublish "$root" "$reclaim" \
            "$reclaim_candidate" >/dev/null 2>&1 || true
          printf 'fwdports: lifecycle lock changed during recovery\n' >&2
          return 75
        fi
        rm -f -- "$lock" || {
          _fwdports_lock_unpublish "$root" "$reclaim" \
            "$reclaim_candidate" >/dev/null 2>&1 || true
          return 1
        }
        ;;
      *)
        printf 'fwdports: lifecycle lock owner cannot be verified\n' >&2
        return 74
        ;;
    esac
  fi

  _fwdports_lock_gc_candidates "$root"

  old_umask=$(umask)
  umask 077
  candidate=$(mktemp "$candidates/candidate.XXXXXXXX") || {
    umask "$old_umask"
    if [[ -n $reclaim_candidate ]] &&
      ! _fwdports_lock_unpublish "$root" "$reclaim" \
        "$reclaim_candidate"; then
      printf 'fwdports: lifecycle recovery ownership changed\n' >&2
      return 74
    fi
    return 1
  }
  umask "$old_umask"
  nonce=${candidate##*/}
  # The candidate is not a lock. Write and protect the complete owner record
  # first; only the subsequent relative symlink atomically makes it
  # authoritative.
  if ! _fwdports_lock_write_owner "$candidate" "$nonce"; then
    rm -f -- "$candidate"
    if [[ -n $reclaim_candidate ]] &&
      ! _fwdports_lock_unpublish "$root" "$reclaim" \
        "$reclaim_candidate"; then
      printf 'fwdports: lifecycle recovery ownership changed\n' >&2
      return 74
    fi
    return 1
  fi
  if _fwdports_lock_publish "$root" "$candidate" "$lock"; then
    publish_status=0
  else
    publish_status=$?
  fi
  if [[ $publish_status -ne 0 ]]; then
    if [[ $publish_status -eq 74 ]]; then
      printf 'fwdports: lifecycle lock publication is invalid\n' >&2
      return 74
    fi
    rm -f -- "$candidate"
    if [[ -n $reclaim_candidate ]] &&
      ! _fwdports_lock_unpublish "$root" "$reclaim" \
        "$reclaim_candidate"; then
      printf 'fwdports: lifecycle recovery ownership changed\n' >&2
      return 74
    fi
    if [[ $publish_status -eq 75 ]]; then
      printf 'fwdports: lifecycle operation is already locked\n' >&2
      return 75
    fi
    printf 'fwdports: cannot publish lifecycle lock\n' >&2
    return 1
  fi
  if [[ -n $reclaim_candidate ]]; then
    if ! _fwdports_lock_unpublish "$root" "$reclaim" \
      "$reclaim_candidate"; then
      _fwdports_lock_unpublish "$root" "$lock" "$candidate" \
        >/dev/null 2>&1 || true
      printf 'fwdports: lifecycle recovery ownership changed\n' >&2
      return 74
    fi
    rm -f -- "$stale_candidate"
  fi
  printf '%s\n' "$candidate"
}

fwdports_lock_release() {
  local root=$1 candidate=$2 lock current

  lock=$root/lifecycle.lock

  case "$candidate" in
    "$root"/lock-candidates/candidate.*) ;;
    *)
      printf 'fwdports: refusing an out-of-root lock candidate\n' >&2
      return 1
      ;;
  esac
  current=$(_fwdports_lock_candidate_for "$root" "$lock") || current=
  [[ -f "$candidate" && ! -L "$candidate" &&
    $current == "$candidate" ]] || {
    printf 'fwdports: lifecycle lock ownership no longer matches\n' >&2
    return 1
  }
  _fwdports_lock_unpublish "$root" "$lock" "$candidate"
}

_fwdports_runtime_sha256_file() {
  local path=$1 output

  # SHA-256 tool availability differs between GNU/Linux and stock macOS. The
  # normalized lowercase digest is part of the on-disk pointer protocol, so
  # every backend must produce exactly the same representation.
  if command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$path") || return 1
    printf '%s\n' "${output%% *}"
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 -- "$path") || return 1
    printf '%s\n' "${output%% *}"
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    output=$(openssl dgst -sha256 "$path") || return 1
    output=${output##*= }
    [[ $output =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    # Bash 3.2 has no lowercase parameter expansion.
    printf '%s\n' "$output" | LC_ALL=C tr 'A-F' 'a-f'
    return 0
  fi
  printf 'fwdports: no usable SHA-256 implementation\n' >&2
  return 1
}

_fwdports_generation_source_record() {
  local line=$1 kind leg field value extra

  # This is the canonical output of config.sh, not another user-facing
  # parser. Revalidating its small record schema here prevents a compromised
  # or accidentally reused temporary file from smuggling ambiguous bytes into
  # the immutable driver ABI.
  [[ -n $line && $line != *$'\r'* ]] || return 1
  IFS=$'\t' read -r kind leg field value extra <<<"$line"
  case "$kind" in
    profile)
      [[ -n $leg && -z $field && -z $value && -z $extra ]]
      ;;
    leg)
      [[ -n $leg && -n $field && -z $value && -z $extra ]]
      ;;
    set)
      [[ -n $leg && -n $field && -n $value && -z $extra ]]
      ;;
    check)
      # Resolved checks contain six fields, so `extra` intentionally carries
      # the final two tab-delimited values and must itself be nonempty.
      [[ -n $leg && -n $field && -n $value && -n $extra ]]
      ;;
    failure)
      [[ -n $leg && -n $field && -z $value && -z $extra ]]
      ;;
    *) return 1 ;;
  esac
}

fwdports_generation_create() {
  local root=$1 source=$2 generations generation nonce manifest_tmp
  local target_override=${3:-}
  local old_umask line first=1 records=0

  [[ -d "$root" && ! -L "$root" ]] || {
    printf 'fwdports: runtime root is unavailable\n' >&2
    return 1
  }
  _fwdports_runtime_validate_node "$root" 'runtime root' || return 1
  [[ -f "$source" && ! -L "$source" ]] || {
    printf 'fwdports: resolved profile is unavailable\n' >&2
    return 1
  }
  _fwdports_runtime_validate_node "$source" 'resolved profile' || return 1
  [[ -z $target_override ||
    ($target_override != -* &&
    $target_override =~ ^[][A-Za-z0-9._:@%+,=-]+$) ]] || {
    printf 'fwdports: target override is unsafe\n' >&2
    return 1
  }

  generations=$root/generations
  old_umask=$(umask)
  umask 077
  if ! mkdir -p "$generations" || ! chmod 0700 "$generations"; then
    umask "$old_umask"
    return 1
  fi
  generation=$(mktemp -d "$generations/generation.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  chmod 0700 "$generation" || {
    rmdir "$generation" 2>/dev/null || true
    return 1
  }
  nonce=${generation##*/}

  old_umask=$(umask)
  umask 077
  manifest_tmp=$(mktemp "$generation/.manifest.XXXXXXXX") || {
    umask "$old_umask"
    rmdir "$generation" 2>/dev/null || true
    return 1
  }
  umask "$old_umask"

  # The random directory already has its final name before any consumer can
  # observe it. Stable absolute paths matter because driver preparation may
  # persist them, and renaming a populated directory would invalidate those
  # references even if publication itself appeared atomic.
  if ! (
    printf 'version\t1\n'
    printf 'generation\t%s\n' "$nonce"
    # Target is immutable desired state and is therefore recorded in the
    # manifest rather than passed through environment or tmux metadata.  The
    # explicit `none` value distinguishes omission from a truncated record.
    printf 'target\t%s\n' "${target_override:-none}"
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $first -eq 1 ]]; then
        first=0
        [[ $line == $'version\t1' ]] || exit 91
        continue
      fi
      _fwdports_generation_source_record "$line" || exit 92
      printf '%s\n' "$line" || exit 93
      records=$((records + 1))
    done <"$source"
    [[ $first -eq 0 && $records -gt 0 ]] || exit 94
  ) >"$manifest_tmp"; then
    rm -f -- "$manifest_tmp"
    rmdir "$generation" 2>/dev/null || true
    printf 'fwdports: resolved profile is not canonical\n' >&2
    return 1
  fi
  if ! chmod 0600 "$manifest_tmp" ||
    ! mv -f -- "$manifest_tmp" "$generation/manifest"; then
    rm -f -- "$manifest_tmp"
    rmdir "$generation" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$generation"
}

fwdports_generation_manifest_digest() {
  local generation=$1 manifest nonce bound_generation

  # Keep this assignment separate for Bash 3.2. In a combined `local`
  # declaration, `$generation` may resolve to a dynamically scoped caller
  # variable rather than the argument assigned earlier on the same line.
  manifest=$generation/manifest

  nonce=${generation##*/}
  [[ $nonce =~ ^generation\.[A-Za-z0-9]+$ &&
    -d "$generation" && ! -L "$generation" &&
    -f "$manifest" && ! -L "$manifest" ]] || {
    printf 'fwdports: generation manifest is unavailable\n' >&2
    return 1
  }
  _fwdports_runtime_validate_node "$generation" generation || return 1
  _fwdports_runtime_validate_node "$manifest" manifest || return 1
  bound_generation=$(LC_ALL=C sed -n '2s/^generation\t//p' "$manifest") ||
    return 1
  [[ $bound_generation == "$nonce" ]] || {
    printf 'fwdports: manifest generation binding is invalid\n' >&2
    return 1
  }
  _fwdports_runtime_sha256_file "$manifest"
}

fwdports_control_write() {
  local generation=$1 expected_digest=$2 phase=$3 desired=$4
  local controller_pid=$5 controller_start=$6 probe=$7
  local control=$generation/control tmp old_umask
  local digest_before digest_after identity_before identity_after nonce

  case "$phase" in
    preparing | running | stopping) ;;
    *)
      printf 'fwdports: invalid generation control phase\n' >&2
      return 1
      ;;
  esac
  [[ $desired == running || $desired == stopped ]] || {
    printf 'fwdports: invalid generation control desire\n' >&2
    return 1
  }
  [[ $controller_pid == none || $controller_pid =~ ^[0-9]+$ ]] || {
    printf 'fwdports: invalid controller pid\n' >&2
    return 1
  }
  [[ $controller_start != *$'\t'* && $controller_start != *$'\n'* &&
    $controller_start != *$'\r'* ]] || {
    printf 'fwdports: invalid controller start identity\n' >&2
    return 1
  }
  case "$probe" in
    unknown | passing | failing | none) ;;
    *)
      printf 'fwdports: invalid probe state\n' >&2
      return 1
      ;;
  esac
  [[ $expected_digest =~ ^[0-9a-f]{64}$ ]] || {
    printf 'fwdports: invalid expected manifest digest\n' >&2
    return 1
  }

  digest_before=$(fwdports_generation_manifest_digest "$generation") ||
    return 1
  identity_before=$(_fwdports_runtime_identity "$generation/manifest") ||
    return 1
  if [[ $digest_before != "$expected_digest" ]]; then
    printf 'fwdports: generation manifest changed before control update\n' >&2
    return 1
  fi
  if [[ -e "$control" || -L "$control" ]]; then
    [[ -f "$control" && ! -L "$control" ]] || {
      printf 'fwdports: generation control has an unsafe type\n' >&2
      return 1
    }
    _fwdports_runtime_validate_node "$control" control || return 1
  fi
  nonce=${generation##*/}
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$generation/.control.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! {
    printf 'version\t1\n'
    printf 'generation\t%s\n' "$nonce"
    printf 'manifest-digest\t%s\n' "$expected_digest"
    printf 'phase\t%s\n' "$phase"
    printf 'desired\t%s\n' "$desired"
    printf 'controller-pid\t%s\n' "$controller_pid"
    printf 'controller-start\t%s\n' "$controller_start"
    printf 'probe\t%s\n' "$probe"
  } >"$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  # Recheck both bytes and inode metadata immediately before publication. A
  # same-UID peer is trusted by design, but this closes accidental replacement
  # races and ensures a stale controller cannot update a reused generation.
  digest_after=$(fwdports_generation_manifest_digest "$generation") || {
    rm -f -- "$tmp"
    return 1
  }
  identity_after=$(_fwdports_runtime_identity "$generation/manifest") || {
    rm -f -- "$tmp"
    return 1
  }
  if [[ $digest_after != "$expected_digest" ||
    $identity_after != "$identity_before" ]]; then
    rm -f -- "$tmp"
    printf 'fwdports: generation manifest changed during control update\n' >&2
    return 1
  fi
  if ! mv -f -- "$tmp" "$control"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fwdports_control_read() {
  local generation=$1 expected_digest=$2 control
  local line key value extra line_number identity_before identity_after
  local version nonce digest phase desired controller_pid controller_start
  local probe attempt=0

  control=$generation/control
  while [[ $attempt -lt 8 ]]; do
    attempt=$((attempt + 1))
    [[ -f "$control" && ! -L "$control" ]] || {
      printf 'fwdports: generation control is unavailable\n' >&2
      return 1
    }
    _fwdports_runtime_validate_node "$control" control || return 1
    identity_before=$(_fwdports_runtime_identity "$control") || return 1
    line_number=0
    version=
    nonce=
    digest=
    phase=
    desired=
    controller_pid=
    controller_start=
    probe=
    while IFS= read -r line || [[ -n $line ]]; do
      line_number=$((line_number + 1))
      IFS=$'\t' read -r key value extra <<<"$line"
      [[ -n $key && -n $value && -z $extra ]] || {
        printf 'fwdports: generation control has an invalid record\n' >&2
        return 1
      }
      case "$line_number:$key" in
        1:version) version=$value ;;
        2:generation) nonce=$value ;;
        3:manifest-digest) digest=$value ;;
        4:phase) phase=$value ;;
        5:desired) desired=$value ;;
        6:controller-pid) controller_pid=$value ;;
        7:controller-start) controller_start=$value ;;
        8:probe) probe=$value ;;
        *)
          printf 'fwdports: generation control schema is invalid\n' >&2
          return 1
          ;;
      esac
    done <"$control"
    identity_after=$(_fwdports_runtime_identity "$control") || return 1
    if [[ $identity_before != "$identity_after" ]]; then
      # Atomic replacement means the open file descriptor above still yielded
      # one complete old record. Retry the pathname to observe a stable current
      # inode; this is normal mutable-state convergence, not corruption. The
      # bound prevents a pathological writer from starving a reader forever.
      continue
    fi
    [[ $line_number -eq 8 && $version == 1 &&
      $nonce == "${generation##*/}" && $digest == "$expected_digest" ]] || {
      printf 'fwdports: generation control binding is invalid\n' >&2
      return 1
    }
    case "$phase" in
      preparing | running | stopping) ;;
      *) return 1 ;;
    esac
    [[ $desired == running || $desired == stopped ]] || return 1
    [[ $controller_pid == none || $controller_pid =~ ^[0-9]+$ ]] || return 1
    case "$probe" in unknown | passing | failing | none) ;; *) return 1 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$phase" "$desired" "$controller_pid" "$controller_start" "$probe"
    return 0
  done
  printf 'fwdports: generation control changed repeatedly while being read\n' \
    >&2
  return 1
}

_fwdports_generation_under_root() {
  local root=$1 generation=$2 nonce generations

  nonce=${generation##*/}
  generations=$root/generations
  [[ $nonce =~ ^generation\.[A-Za-z0-9]+$ &&
    $generation == "$generations/$nonce" &&
    -d "$generations" && ! -L "$generations" &&
    -d "$generation" && ! -L "$generation" ]] || {
    printf 'fwdports: generation is outside the runtime root\n' >&2
    return 1
  }
  _fwdports_runtime_validate_node "$generations" generations || return 1
  _fwdports_runtime_validate_node "$generation" generation || return 1
}

fwdports_pointer_read() {
  local root=$1 kind=$2 pointer line key value extra line_number=0
  local version='' nonce='' digest='' generation actual_digest
  local identity_before identity_after

  [[ $kind == pending || $kind == active ]] || {
    printf 'fwdports: invalid pointer kind\n' >&2
    return 1
  }
  [[ -d "$root" && ! -L "$root" ]] || return 1
  _fwdports_runtime_validate_node "$root" 'runtime root' || return 1
  pointer=$root/$kind
  [[ -f "$pointer" && ! -L "$pointer" ]] || {
    printf 'fwdports: %s pointer is unavailable\n' "$kind" >&2
    return 1
  }
  _fwdports_runtime_validate_node "$pointer" "$kind pointer" || return 1
  identity_before=$(_fwdports_runtime_identity "$pointer") || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line_number=$((line_number + 1))
    IFS=$'\t' read -r key value extra <<<"$line"
    [[ -n $key && -n $value && -z $extra ]] || {
      printf 'fwdports: %s pointer has an invalid record\n' "$kind" >&2
      return 1
    }
    case "$line_number:$key" in
      1:version) version=$value ;;
      2:generation) nonce=$value ;;
      3:manifest-digest) digest=$value ;;
      *)
        printf 'fwdports: %s pointer schema is invalid\n' "$kind" >&2
        return 1
        ;;
    esac
  done <"$pointer"
  identity_after=$(_fwdports_runtime_identity "$pointer") || return 1
  [[ $identity_before == "$identity_after" ]] || {
    printf 'fwdports: %s pointer changed while being read\n' "$kind" >&2
    return 1
  }
  [[ $line_number -eq 3 && $version == 1 &&
    $nonce =~ ^generation\.[A-Za-z0-9]+$ &&
    $digest =~ ^[0-9a-f]{64}$ ]] || {
    printf 'fwdports: %s pointer binding is invalid\n' "$kind" >&2
    return 1
  }
  generation=$root/generations/$nonce
  _fwdports_generation_under_root "$root" "$generation" || return 1
  actual_digest=$(fwdports_generation_manifest_digest "$generation") ||
    return 1
  [[ $actual_digest == "$digest" ]] || {
    printf 'fwdports: %s pointer manifest digest does not match\n' \
      "$kind" >&2
    return 1
  }
  fwdports_control_read "$generation" "$digest" >/dev/null || return 1
  printf '%s\t%s\n' "$generation" "$digest"
}

fwdports_pointer_publish() {
  local root=$1 kind=$2 generation=$3 expected_digest=$4
  local pointer tmp old_umask actual_digest identity_before identity_after

  [[ $kind == pending || $kind == active ]] || {
    printf 'fwdports: invalid pointer kind\n' >&2
    return 1
  }
  _fwdports_generation_under_root "$root" "$generation" || return 1
  actual_digest=$(fwdports_generation_manifest_digest "$generation") ||
    return 1
  [[ $actual_digest == "$expected_digest" ]] || {
    printf 'fwdports: generation manifest changed before pointer publish\n' >&2
    return 1
  }
  fwdports_control_read "$generation" "$expected_digest" >/dev/null ||
    return 1
  identity_before=$(_fwdports_runtime_identity "$generation/manifest") ||
    return 1
  pointer=$root/$kind
  if [[ -e "$pointer" || -L "$pointer" ]]; then
    # Existing evidence is replaceable only when it is itself valid. Silently
    # overwriting a malformed pointer would convert corruption into authority
    # to act on a different generation.
    fwdports_pointer_read "$root" "$kind" >/dev/null || return 1
  fi

  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$root/.$kind.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! {
    printf 'version\t1\n'
    printf 'generation\t%s\n' "${generation##*/}"
    printf 'manifest-digest\t%s\n' "$expected_digest"
  } >"$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  actual_digest=$(fwdports_generation_manifest_digest "$generation") || {
    rm -f -- "$tmp"
    return 1
  }
  identity_after=$(_fwdports_runtime_identity "$generation/manifest") || {
    rm -f -- "$tmp"
    return 1
  }
  if [[ $actual_digest != "$expected_digest" ||
    $identity_after != "$identity_before" ]] ||
    ! fwdports_control_read "$generation" "$expected_digest" \
      >/dev/null; then
    rm -f -- "$tmp"
    printf 'fwdports: generation changed during pointer publish\n' >&2
    return 1
  fi
  if ! mv -f -- "$tmp" "$pointer"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fwdports_pointer_remove() {
  local root=$1 kind=$2 generation=$3 digest=$4 pointer record
  local identity_before identity_after

  record=$(fwdports_pointer_read "$root" "$kind") || return 1
  [[ $record == "$generation"$'\t'"$digest" ]] || {
    printf 'fwdports: refusing to remove a changed %s pointer\n' "$kind" >&2
    return 1
  }
  pointer=$root/$kind
  identity_before=$(_fwdports_runtime_identity "$pointer") || return 1
  # Repeat the full semantic read, not just stat, immediately before unlink.
  # This keeps a stale controller from deleting a newly published pointer that
  # happens to occupy the same pathname.
  record=$(fwdports_pointer_read "$root" "$kind") || return 1
  identity_after=$(_fwdports_runtime_identity "$pointer") || return 1
  [[ $record == "$generation"$'\t'"$digest" &&
    $identity_after == "$identity_before" ]] || {
    printf 'fwdports: %s pointer changed before removal\n' "$kind" >&2
    return 1
  }
  rm -f -- "$pointer"
}

fwdports_generation_remove() {
  local root=$1 generation=$2 digest=$3 actual record kind
  local root_identity generations_identity

  _fwdports_generation_under_root "$root" "$generation" || return 1
  actual=$(fwdports_generation_manifest_digest "$generation") || return 1
  [[ $actual == "$digest" ]] || {
    printf 'fwdports: refusing to remove a changed generation\n' >&2
    return 1
  }
  for kind in active pending; do
    if [[ -e "$root/$kind" || -L "$root/$kind" ]]; then
      record=$(fwdports_pointer_read "$root" "$kind") || return 1
      [[ $record != "$generation"$'\t'"$digest" ]] || {
        printf 'fwdports: generation is still published by %s\n' "$kind" >&2
        return 1
      }
    fi
  done
  root_identity=$(_fwdports_runtime_identity "$root") || return 1
  generations_identity=$(_fwdports_runtime_identity "$root/generations") ||
    return 1
  _fwdports_generation_under_root "$root" "$generation" || return 1
  [[ $root_identity == "$(_fwdports_runtime_identity "$root")" &&
  $generations_identity == "$(_fwdports_runtime_identity "$root/generations")" ]] || {
    printf 'fwdports: generation namespace changed before removal\n' >&2
    return 1
  }

  # Recursive removal is confined to an exact, already-authenticated random
  # child. `rm` unlinks symlinks inside that tree rather than traversing their
  # targets; the repeated namespace checks above prevent `..`, sibling, and
  # replacement paths from broadening this destructive boundary.
  rm -rf -- "$generation" || return 1
  [[ ! -e "$generation" && ! -L "$generation" ]]
}

fwdports_runtime_init() {
  local state_home root parent canonical_parent old_umask

  if [[ ${XDG_STATE_HOME:-} == /* ]]; then
    state_home=$XDG_STATE_HOME
  else
    [[ ${HOME:-} == /* ]] || {
      printf 'fwdports: HOME must be an absolute path\n' >&2
      return 1
    }
    state_home=$HOME/.local/state
  fi
  root=$state_home/fwdports
  parent=${root%/*}

  old_umask=$(umask)
  umask 077
  if ! mkdir -p "$parent"; then
    umask "$old_umask"
    printf 'fwdports: cannot create state parent: %s\n' "$parent" >&2
    return 1
  fi
  umask "$old_umask"
  [[ -d "$parent" && ! -L "$parent" ]] || {
    printf 'fwdports: state parent is not a regular directory: %s\n' \
      "$parent" >&2
    return 1
  }
  canonical_parent=$(cd -P -- "$parent" && pwd -P) || {
    printf 'fwdports: cannot resolve state parent: %s\n' "$parent" >&2
    return 1
  }
  root=$canonical_parent/fwdports
  if [[ -e "$root" || -L "$root" ]]; then
    [[ -d "$root" && ! -L "$root" ]] || {
      printf 'fwdports: state root is not a regular directory: %s\n' \
        "$root" >&2
      return 1
    }
  else
    old_umask=$(umask)
    umask 077
    if ! mkdir "$root"; then
      umask "$old_umask"
      printf 'fwdports: cannot create state root: %s\n' "$root" >&2
      return 1
    fi
    umask "$old_umask"
  fi
  if ! chmod 0700 "$root"; then
    printf 'fwdports: cannot protect state root: %s\n' "$root" >&2
    return 1
  fi
  printf '%s\n' "$root"
}
