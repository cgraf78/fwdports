#!/usr/bin/env bash
# Data-only configuration support lives in this checkout-owned module. Keeping
# it separate from the CLI makes the parser reusable by validation, start, and
# tests without duplicating policy or evaluating configuration as shell code.

_fwdports_config_identifier() {
  [[ $1 =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]
}

_fwdports_config_value() {
  local value=$1 token_re='^[][A-Za-z0-9._/:@%+,=-]+$'
  # Leading dashes would let data become an option if a driver ever misplaced
  # an argv boundary. The allowlist also excludes every shell metacharacter,
  # control character, and whitespace byte without trying to quote a language.
  [[ $value != -* && $value =~ $token_re ]]
}

_fwdports_config_error() {
  printf 'fwdports: config line %s: %s\n' "$1" "$2" >&2
  return 1
}

_fwdports_config_find_profile() {
  local wanted=$1 index

  # Bash 3.2 cannot pass arrays by reference. These helpers deliberately use
  # Bash's dynamic function scope: `profile_names` and `found_index` are local
  # to the active resolver invocation, so no parser state leaks after return.
  found_index=-1
  for ((index = 0; index < ${#profile_names[@]}; index++)); do
    if [[ ${profile_names[index]} == "$wanted" ]]; then
      found_index=$index
      return 0
    fi
  done
  return 1
}

_fwdports_config_leg_exists() {
  local wanted=$1 line kind leg rest

  for line in "${resolved[@]}"; do
    IFS=$'\t' read -r kind leg rest <<<"$line"
    if [[ $kind == leg && $leg == "$wanted" ]]; then
      return 0
    fi
  done
  return 1
}

_fwdports_config_resolve_profile() {
  local name=$1 depth=$2 chain=$3 found_index=-1 parent records
  local record kind leg _record_field _record_value _record_extra kept_record
  local kept_kind kept_leg _kept_field _kept_value _kept_extra
  local -a kept=()

  if ((depth > 20)); then
    printf 'fwdports: profile inheritance exceeds depth 20: %s\n' "$name" >&2
    return 1
  fi
  case "$chain" in
    *"|$name|"*)
      printf 'fwdports: profile inheritance cycle includes: %s\n' "$name" >&2
      return 1
      ;;
  esac
  if ! _fwdports_config_find_profile "$name"; then
    printf 'fwdports: inherited profile not found: %s\n' "$name" >&2
    return 1
  fi

  parent=${profile_parents[found_index]}
  records=${profile_records[found_index]}
  if [[ -n $parent ]] &&
    ! _fwdports_config_resolve_profile "$parent" "$((depth + 1))" \
      "$chain|$name|"; then
    return 1
  fi

  while IFS= read -r record || [[ -n $record ]]; do
    [[ -n $record ]] || continue
    IFS=$'\t' read -r kind leg _record_field _record_value \
      _record_extra <<<"$record"
    case "$kind" in
      leg)
        if _fwdports_config_leg_exists "$leg"; then
          printf 'fwdports: duplicate inherited leg: %s\n' "$leg" >&2
          return 1
        fi
        resolved+=("$record")
        ;;
      set | check | failure)
        if ! _fwdports_config_leg_exists "$leg"; then
          printf 'fwdports: record refers to undeclared leg: %s\n' "$leg" >&2
          return 1
        fi
        resolved+=("$record")
        ;;
      reset)
        if ! _fwdports_config_leg_exists "$leg"; then
          printf 'fwdports: reset refers to undeclared leg: %s\n' "$leg" >&2
          return 1
        fi
        # Reset removes inherited policy but deliberately retains the leg and
        # its driver identity. This keeps inheritance from changing transport
        # type indirectly while still allowing a child to rebuild its options.
        kept=()
        for kept_record in "${resolved[@]}"; do
          IFS=$'\t' read -r kept_kind kept_leg _kept_field _kept_value \
            _kept_extra <<<"$kept_record"
          if [[ $kept_leg == "$leg" &&
            ($kept_kind == set || $kept_kind == check ||
              $kept_kind == failure) ]]; then
            continue
          fi
          kept+=("$kept_record")
        done
        resolved=("${kept[@]}")
        ;;
      *)
        printf 'fwdports: internal unsupported config record: %s\n' "$kind" >&2
        return 1
        ;;
    esac
  done <<<"$records"
}

fwdports_config_resolve() {
  local config=$1 selected_profile=$2 output=$3
  local line line_number=0 record tmp old_umask parent current_index=-1
  local profile_name existing found_index=-1
  local -a fields=() profile_names=() profile_parents=()
  local -a profile_records=() resolved=()

  if [[ ! -f "$config" || -L "$config" ]]; then
    printf 'fwdports: config is not a regular file: %s\n' "$config" >&2
    return 1
  fi
  if ! _fwdports_config_identifier "$selected_profile"; then
    printf 'fwdports: invalid profile name: %s\n' "$selected_profile" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    # V1 deliberately supports only whole-line comments. Treating `#` as data
    # elsewhere avoids a second quoting language and keeps parsing independent
    # of shell expansion rules.
    [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue
    fields=()
    read -r -a fields <<<"$line"
    case ${fields[0]:-} in
      profile)
        parent=
        if [[ ${#fields[@]} -eq 4 && ${fields[2]} == extends ]]; then
          parent=${fields[3]}
        elif [[ ${#fields[@]} -ne 2 ]]; then
          _fwdports_config_error "$line_number" 'invalid profile record'
          return 1
        fi
        if ! _fwdports_config_identifier "${fields[1]:-}"; then
          _fwdports_config_error "$line_number" 'invalid profile record'
          return 1
        fi
        if [[ -n $parent ]] && ! _fwdports_config_identifier "$parent"; then
          _fwdports_config_error "$line_number" 'invalid parent profile name'
          return 1
        fi
        profile_name=${fields[1]}
        for existing in "${profile_names[@]}"; do
          if [[ $existing == "$profile_name" ]]; then
            _fwdports_config_error "$line_number" \
              "duplicate profile: $profile_name"
            return 1
          fi
        done
        profile_names+=("$profile_name")
        profile_parents+=("$parent")
        profile_records+=("")
        current_index=$((${#profile_names[@]} - 1))
        ;;
      leg)
        if [[ $current_index -lt 0 || ${#fields[@]} -lt 2 ||
          ${#fields[@]} -gt 3 ]] ||
          ! _fwdports_config_identifier "${fields[1]:-}" ||
          { [[ ${#fields[@]} -eq 3 ]] &&
            ! _fwdports_config_identifier "${fields[2]}"; }; then
          _fwdports_config_error "$line_number" 'invalid leg record'
          return 1
        fi
        printf -v record 'leg\t%s\t%s' "${fields[1]}" "${fields[2]:-ssh}"
        if [[ ${profile_records[current_index]} == *$'\n'"leg"$'\t'"${fields[1]}"$'\t'* ||
          ${profile_records[current_index]} == "leg"$'\t'"${fields[1]}"$'\t'* ]]; then
          _fwdports_config_error "$line_number" "duplicate leg: ${fields[1]}"
          return 1
        fi
        if [[ -n ${profile_records[current_index]} ]]; then
          profile_records[current_index]="${profile_records[current_index]}"$'\n'"$record"
        else
          profile_records[current_index]=$record
        fi
        ;;
      set)
        if [[ $current_index -lt 0 || ${#fields[@]} -ne 4 ]] ||
          ! _fwdports_config_identifier "${fields[1]:-}" ||
          ! _fwdports_config_identifier "${fields[2]:-}" ||
          ! _fwdports_config_value "${fields[3]:-}"; then
          _fwdports_config_error "$line_number" 'invalid set record'
          return 1
        fi
        printf -v record 'set\t%s\t%s\t%s' \
          "${fields[1]}" "${fields[2]}" "${fields[3]}"
        if [[ -n ${profile_records[current_index]} ]]; then
          profile_records[current_index]="${profile_records[current_index]}"$'\n'"$record"
        else
          profile_records[current_index]=$record
        fi
        ;;
      reset)
        if [[ $current_index -lt 0 || ${#fields[@]} -ne 2 ]] ||
          ! _fwdports_config_identifier "${fields[1]:-}"; then
          _fwdports_config_error "$line_number" 'invalid reset record'
          return 1
        fi
        printf -v record 'reset\t%s' "${fields[1]}"
        if [[ -n ${profile_records[current_index]} ]]; then
          profile_records[current_index]="${profile_records[current_index]}"$'\n'"$record"
        else
          profile_records[current_index]=$record
        fi
        ;;
      check)
        if [[ $current_index -lt 0 || ${#fields[@]} -lt 4 ||
          ${#fields[@]} -gt 6 ]] ||
          ! _fwdports_config_identifier "${fields[1]:-}"; then
          _fwdports_config_error "$line_number" 'invalid check record'
          return 1
        fi
        case ${fields[2]} in
          loopback)
            if [[ ${#fields[@]} -lt 4 || ${#fields[@]} -gt 5 ||
              ! ${fields[3]} =~ ^[0-9]+$ ]] ||
              ((fields[3] < 1 || fields[3] > 65535)); then
              _fwdports_config_error "$line_number" \
                'invalid loopback check record'
              return 1
            fi
            if [[ ${#fields[@]} -eq 5 ]] &&
              ! _fwdports_config_identifier "${fields[4]}"; then
              _fwdports_config_error "$line_number" 'invalid check label'
              return 1
            fi
            printf -v record 'check\t%s\tloopback\t127.0.0.1\t%s\t%s' \
              "${fields[1]}" "${fields[3]}" "${fields[4]:-${fields[1]}}"
            ;;
          tcp)
            if [[ ${#fields[@]} -lt 5 || ${#fields[@]} -gt 6 ]] ||
              ! _fwdports_config_value "${fields[3]}" ||
              [[ ! ${fields[4]} =~ ^[0-9]+$ ]] ||
              ((fields[4] < 1 || fields[4] > 65535)); then
              _fwdports_config_error "$line_number" 'invalid TCP check record'
              return 1
            fi
            if [[ ${#fields[@]} -eq 6 ]] &&
              ! _fwdports_config_identifier "${fields[5]}"; then
              _fwdports_config_error "$line_number" 'invalid check label'
              return 1
            fi
            printf -v record 'check\t%s\ttcp\t%s\t%s\t%s' \
              "${fields[1]}" "${fields[3]}" "${fields[4]}" \
              "${fields[5]:-${fields[1]}}"
            ;;
          *)
            _fwdports_config_error "$line_number" 'unknown check type'
            return 1
            ;;
        esac
        if [[ -n ${profile_records[current_index]} ]]; then
          profile_records[current_index]="${profile_records[current_index]}"$'\n'"$record"
        else
          profile_records[current_index]=$record
        fi
        ;;
      failure)
        if [[ $current_index -lt 0 || ${#fields[@]} -ne 3 ]] ||
          ! _fwdports_config_identifier "${fields[1]:-}" ||
          [[ ${fields[2]:-} != restart && ${fields[2]:-} != preserve ]]; then
          _fwdports_config_error "$line_number" 'invalid failure record'
          return 1
        fi
        printf -v record 'failure\t%s\t%s' "${fields[1]}" "${fields[2]}"
        if [[ -n ${profile_records[current_index]} ]]; then
          profile_records[current_index]="${profile_records[current_index]}"$'\n'"$record"
        else
          profile_records[current_index]=$record
        fi
        ;;
      *)
        _fwdports_config_error "$line_number" 'unknown directive'
        return 1
        ;;
    esac
  done <"$config"

  if ! _fwdports_config_find_profile "$selected_profile"; then
    printf 'fwdports: profile not found: %s\n' "$selected_profile" >&2
    return 1
  fi
  if ! _fwdports_config_resolve_profile "$selected_profile" 0 ''; then
    return 1
  fi

  # Serialize only after complete validation. A malformed later record cannot
  # leave a partial resolved profile for a caller to mistake for valid state.
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "${output}.tmp.XXXXXXXX") || {
    umask "$old_umask"
    printf 'fwdports: cannot create resolved config beside %s\n' "$output" >&2
    return 1
  }
  umask "$old_umask"
  if ! {
    printf 'version\t1\n'
    printf 'profile\t%s\n' "$selected_profile"
    printf '%s\n' "${resolved[@]}"
  } >"$tmp"; then
    rm -f -- "$tmp"
    printf 'fwdports: cannot write resolved config: %s\n' "$output" >&2
    return 1
  fi
  chmod 0600 "$tmp" || {
    rm -f -- "$tmp"
    printf 'fwdports: cannot protect resolved config: %s\n' "$output" >&2
    return 1
  }
  if ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    printf 'fwdports: cannot publish resolved config: %s\n' "$output" >&2
    return 1
  fi
}
