#!/usr/bin/env bash
# nixx-shellint — static linter for nixx shell blocks embedded in Nix.
# Source-driven (no eval): tree-sitter-nix locates each `bash ''…''` block and
# analyses the shell↔Nix boundary; bash bodies are then shellcheck'd and their
# required env is reported.
#
# Env (baked by the Nix wrapper, overridable for local runs):
#   NIXX_TSN_PARSER  tree-sitter-nix  parser .so
#   NIXX_TSB_PARSER  tree-sitter-bash parser .so
# Flags: --no-nix --no-shellcheck --no-envcheck  --exclude=SC2086,SC2046
set -uo pipefail

# Parser paths are baked by the Nix wrapper (placeholders), but stay overridable
# for local runs / tests.
NIXX_TSN_PARSER="${NIXX_TSN_PARSER:-@TSN_PARSER@}"
NIXX_TSB_PARSER="${NIXX_TSB_PARSER:-@TSB_PARSER@}"
: "${NIXX_TSN_PARSER:?}" "${NIXX_TSB_PARSER:?}"

# nixx block constructors (space-padded for membership test)
_CTORS=" bash sh py uv bun ts node deno perl ruby lua "
_DO_NIX=1 _DO_SC=1 _DO_ENV=1 _SC_EXCLUDE="SC2154,SC2153"
_FATAL=0 _WARN=0
_PATHS=()
_EXCLUDE_PATHS=()

for _a in "$@"; do
  case "$_a" in
    --no-nix) _DO_NIX=0 ;;
    --no-shellcheck) _DO_SC=0 ;;
    --no-envcheck) _DO_ENV=0 ;;
    --exclude=*) _SC_EXCLUDE="$_SC_EXCLUDE,${_a#--exclude=}" ;;
    --exclude-path=*) _EXCLUDE_PATHS+=("${_a#--exclude-path=}") ;;
    *) _PATHS+=("$_a") ;;
  esac
done
[[ ${#_PATHS[@]} -eq 0 ]] && _PATHS=(".")

# find(1) prune args: always skip .git, plus any --exclude-path globs
_FIND_PRUNE=(-not -path '*/.git/*')
for _ex in ${_EXCLUDE_PATHS[@]+"${_EXCLUDE_PATHS[@]}"}; do
  _FIND_PRUNE+=(-not -path "$_ex")
done

# expand dirs → *.nix files
_FILES=()
for _p in "${_PATHS[@]}"; do
  if [[ -d "$_p" ]]; then
    while IFS= read -r _ff; do _FILES+=("$_ff"); done \
      < <(find "$_p" -type f -name '*.nix' "${_FIND_PRUNE[@]}" | sort)
  elif [[ -f "$_p" ]]; then
    _FILES+=("$_p")
  fi
done

# report FILE LINE COL PASS SEV MSG
_report() {
  local sev="$4"
  printf '%s:%s:%s  [%s] %s  %s\n' "$1" "$(($2 + 1))" "$(($3 + 1))" "$5" "$sev" "$6"
  case "$sev" in FATAL) _FATAL=$((_FATAL + 1)) ;; WARN) _WARN=$((_WARN + 1)) ;; esac
}

# last identifier token of a function expression text ("nixx.sh" → "sh")
_last_id() {
  local t="$1"
  t="${t//[^A-Za-z0-9_]/ }"   # non-id chars → space
  t="${t##* }"                # last token
  printf '%s' "$t"
}
# is the call's function a nixx block constructor? (filters out plain `f ''…''`)
_is_ctor() {
  local lang; lang=$(_last_id "$1")
  case "$_CTORS" in *" $lang "*) return 0 ;; *) return 1 ;; esac
}

# (a_r,a_c) <= (b_r,b_c)
_le() { (( $1 < $3 )) && return 0; (( $1 == $3 && $2 <= $4 )) && return 0; return 1; }
# does range A (1..4) contain range B (5..8) ?
_contains() {
  _le "$1" "$2" "$5" "$6" && _le "$7" "$8" "$3" "$4"
}
# do ranges A (1..4) and B (5..8) overlap ?
_overlap() {
  _le "$3" "$4" "$5" "$6" && return 1   # A_end <= B_start
  _le "$7" "$8" "$1" "$2" && return 1   # B_end <= A_start
  return 0
}

_NIX_Q='(apply_expression function: (_) @fn argument: (indented_string_expression) @body) @call
(interpolation) @interp
(ERROR) @err
(with_expression) @with'

_BASH_REQ_Q='(simple_expansion) @ref
(expansion) @ref
(variable_assignment name: (variable_name) @bound)
(variable_assignment name: (subscript name: (variable_name) @bound))
(declaration_command (variable_name) @bound)
(for_statement variable: (variable_name) @bound)
((command name: (command_name) @c argument: (word) @bound)
 (#match? @c "^(read|mapfile|readarray|getopts)$"))'

# capture-line regex for `tree-sitter query` output (index prefix optional)
_CAP_RE='capture: ([0-9]+ - )?([a-z]+), start: \(([0-9]+), ([0-9]+)\), end: \(([0-9]+), ([0-9]+)\)'
# shellcheck disable=SC2016
_TXT_RE='text: `(.*)`'

# reconstruct shell text of an indented_string body slice in $1 (file) over
# range r2..r5 (0-based rows) c3..c6 (cols); strips ''…'' and resolves ''$ '''.
_body_text() {
  local f="$1" sr="$2" sc="$3" er="$4" ec="$5"
  awk -v sr="$sr" -v sc="$sc" -v er="$er" -v ec="$ec" '
    NR-1 < sr || NR-1 > er { next }
    {
      line=$0; r=NR-1; s=0; e=length(line)
      if (r==sr) s=sc
      if (r==er) e=ec
      out = out substr(line, s+1, e-s) "\n"
    }
    END { printf "%s", out }
  ' "$f" \
    | sed -e 's/^'\'''\''//' -e 's/'\'''\''$//' \
    | sed -e "s/''\\\$/\$/g" -e "s/'''/''/g"
}

# env-check classifier over a reconstructed bash body on stdin → required names
_env_required() {
  local out line cap name txt bound=" " i j n nested
  local -a rsr=() rsc=() rer=() rec=() rtxt=() reqlist=()
  out=$(tree-sitter query --lib-path "$NIXX_TSB_PARSER" --lang-name bash \
        <(printf '%s' "$_BASH_REQ_Q") /dev/stdin 2>/dev/null) || return 0
  # shellcheck disable=SC2016
  local re='capture: ([0-9]+ - )?([a-z]+), start: \(([0-9]+), ([0-9]+)\), end: \(([0-9]+), ([0-9]+)\), text: `(.*)`'
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    cap="${BASH_REMATCH[2]}"
    if [[ "$cap" == bound ]]; then bound+="${BASH_REMATCH[7]} "
    elif [[ "$cap" == ref ]]; then
      rsr+=("${BASH_REMATCH[3]}"); rsc+=("${BASH_REMATCH[4]}")
      rer+=("${BASH_REMATCH[5]}"); rec+=("${BASH_REMATCH[6]}")
      rtxt+=("${BASH_REMATCH[7]}")
    fi
  done <<< "$out"
  n=${#rtxt[@]}
  for (( i=0; i<n; i++ )); do
    nested=0
    for (( j=0; j<n; j++ )); do
      [[ $i -eq $j ]] && continue
      if _le "${rsr[j]}" "${rsc[j]}" "${rsr[i]}" "${rsc[i]}" \
         && _le "${rer[i]}" "${rec[i]}" "${rer[j]}" "${rec[j]}" \
         && ! { [[ "${rsr[i]}" == "${rsr[j]}" && "${rsc[i]}" == "${rsc[j]}" \
              && "${rer[i]}" == "${rer[j]}" && "${rec[i]}" == "${rec[j]}" ]]; }
      then nested=1; break; fi
    done
    [[ $nested -eq 1 ]] && continue
    txt="${rtxt[i]}"; name=""
    if   [[ "$txt" =~ ^[[:space:]]*\$([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$ ]]; then name="${BASH_REMATCH[1]}"
    elif [[ "$txt" =~ ^[[:space:]]*\$\{([A-Za-z_][A-Za-z0-9_]*)\}[[:space:]]*$ ]]; then name="${BASH_REMATCH[1]}"
    elif [[ "$txt" =~ ^[[:space:]]*\$\{([A-Za-z_][A-Za-z0-9_]*):?\? ]]; then name="${BASH_REMATCH[1]}"
    else continue; fi
    case "$bound" in *" $name "*) continue ;; esac
    case " ${reqlist[*]-} " in *" $name "*) ;; *) reqlist+=("$name") ;; esac
  done
  printf '%s\n' "${reqlist[@]-}"
}

lint_file() {
  local f="$1" out line
  out=$(tree-sitter query --lib-path "$NIXX_TSN_PARSER" --lang-name nix \
        <(printf '%s' "$_NIX_Q") "$f" 2>/dev/null) || return 0

  # parse captures
  local -a c_sr=() c_sc=() c_er=() c_ec=() c_fn=()   # block calls
  local -a b_sr=() b_sc=() b_er=() b_ec=()           # body ranges (same index as calls)
  local -a w_sr=() w_sc=() w_er=() w_ec=()           # with ranges
  local -a i_sr=() i_sc=() i_er=() i_ec=() i_tx=()   # interpolations
  local -a e_sr=() e_sc=() e_er=() e_ec=()           # errors
  local name sr sc er ec txt
  # within a pattern-0 match tree-sitter emits in node order: call, then fn, then
  # body. On `call` push a new entry; `fn`/`body` fill the most recent one.
  while IFS= read -r line; do
    if [[ "$line" =~ $_CAP_RE ]]; then
      name="${BASH_REMATCH[2]}"; sr="${BASH_REMATCH[3]}"; sc="${BASH_REMATCH[4]}"
      er="${BASH_REMATCH[5]}"; ec="${BASH_REMATCH[6]}"
      txt=""; [[ "$line" =~ $_TXT_RE ]] && txt="${BASH_REMATCH[1]}"
      case "$name" in
        call)
          c_sr+=("$sr"); c_sc+=("$sc"); c_er+=("$er"); c_ec+=("$ec"); c_fn+=("")
          b_sr+=("-1"); b_sc+=("-1"); b_er+=("-1"); b_ec+=("-1") ;;
        fn)   c_fn[${#c_fn[@]} - 1]="$txt" ;;
        body)
          local _bx=$(( ${#b_sr[@]} - 1 ))
          b_sr[_bx]="$sr"; b_sc[_bx]="$sc"; b_er[_bx]="$er"; b_ec[_bx]="$ec" ;;
        with) w_sr+=("$sr"); w_sc+=("$sc"); w_er+=("$er"); w_ec+=("$ec") ;;
        interp) i_sr+=("$sr"); i_sc+=("$sc"); i_er+=("$er"); i_ec+=("$ec"); i_tx+=("$txt") ;;
        err)  e_sr+=("$sr"); e_sc+=("$sc"); e_er+=("$er"); e_ec+=("$ec") ;;
      esac
    fi
  done <<< "$out"

  local nb=${#c_sr[@]} ni=${#i_sr[@]} ne=${#e_sr[@]} nw=${#w_sr[@]}
  local bi ii ei wi lang has_with body rn

  # ---- nix-boundary pass ----
  local -a e_claimed=()
  for (( ei=0; ei<ne; ei++ )); do e_claimed+=(0); done
  if [[ $_DO_NIX -eq 1 ]]; then
    # one FATAL per block whose body overlaps an ERROR (shell-op breaks Nix);
    # claim those errors so they aren't also reported as generic syntax errors.
    for (( bi=0; bi<nb; bi++ )); do
      _is_ctor "${c_fn[bi]}" || continue
      local hit=-1
      for (( ei=0; ei<ne; ei++ )); do
        if _overlap "${b_sr[bi]}" "${b_sc[bi]}" "${b_er[bi]}" "${b_ec[bi]}" \
                    "${e_sr[ei]}" "${e_sc[ei]}" "${e_er[ei]}" "${e_ec[ei]}"; then
          e_claimed[ei]=1
          [[ $hit -lt 0 ]] && hit=$ei
        fi
      done
      if [[ $hit -ge 0 ]]; then
        _report "$f" "${e_sr[hit]}" "${e_sc[hit]}" FATAL nix \
          "shell expansion breaks Nix in this block — escape it as '\''\${…} (shell-only form like \${#x} \${x[@]} \${x^^})"
      fi
    done
    # errors not inside any block → generic Nix syntax error
    for (( ei=0; ei<ne; ei++ )); do
      [[ "${e_claimed[ei]}" -eq 1 ]] && continue
      _report "$f" "${e_sr[ei]}" "${e_sc[ei]}" FATAL nix "Nix syntax error"
    done
    # bare \${IDENT} interpolations inside blocks, no enclosing with → eval death
    for (( ii=0; ii<ni; ii++ )); do
      [[ "${i_tx[ii]}" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]] || continue
      local in_b=-1
      for (( bi=0; bi<nb; bi++ )); do
        if _contains "${b_sr[bi]}" "${b_sc[bi]}" "${b_er[bi]}" "${b_ec[bi]}" \
                     "${i_sr[ii]}" "${i_sc[ii]}" "${i_er[ii]}" "${i_ec[ii]}"; then in_b=$bi; break; fi
      done
      [[ $in_b -lt 0 ]] && continue
      _is_ctor "${c_fn[in_b]}" || continue
      has_with=0
      for (( wi=0; wi<nw; wi++ )); do
        if _contains "${w_sr[wi]}" "${w_sc[wi]}" "${w_er[wi]}" "${w_ec[wi]}" \
                     "${c_sr[in_b]}" "${c_sc[in_b]}" "${c_er[in_b]}" "${c_ec[in_b]}"; then has_with=1; break; fi
      done
      if [[ $has_with -eq 0 ]]; then
        _report "$f" "${i_sr[ii]}" "${i_sc[ii]}" FATAL nix \
          "bare ${i_tx[ii]} needs a \`with\` scope to source-read, else Nix eval fails — or escape as '\''${i_tx[ii]}"
      fi
    done
  fi

  # ---- shellcheck + env passes on clean bash/sh blocks ----
  for (( bi=0; bi<nb; bi++ )); do
    lang=$(_last_id "${c_fn[bi]}")
    case "$lang" in bash | sh) ;; *) continue ;; esac
    # skip blocks whose body overlaps an ERROR (already FATAL'd; parse unreliable)
    local dirty=0
    for (( ei=0; ei<ne; ei++ )); do
      if _overlap "${b_sr[bi]}" "${b_sc[bi]}" "${b_er[bi]}" "${b_ec[bi]}" \
                  "${e_sr[ei]}" "${e_sc[ei]}" "${e_er[ei]}" "${e_ec[ei]}"; then dirty=1; break; fi
    done
    [[ $dirty -eq 1 ]] && continue
    body=$(_body_text "$f" "${b_sr[bi]}" "${b_sc[bi]}" "${b_er[bi]}" "${b_ec[bi]}")

    if [[ $_DO_SC -eq 1 ]]; then
      # wrap in a function so `local`/`return` are valid — nixx task bodies run
      # inside a generated function. 2 prefix lines (shebang + `_block() {`), so a
      # finding on shellcheck line L maps to source row  b_sr + (L - 3).
      local sc_out
      sc_out=$(printf '#!/usr/bin/env bash\n_block() {\n%s\n}\n' "$body" \
               | shellcheck -s bash --exclude="$_SC_EXCLUDE" --format=gcc /dev/stdin 2>/dev/null) || true
      if [[ -n "$sc_out" ]]; then
        while IFS= read -r line; do
          [[ "$line" =~ ^[^:]+:([0-9]+):([0-9]+):\ (.*)$ ]] || continue
          local bl="${BASH_REMATCH[1]}" bc="${BASH_REMATCH[2]}" msg="${BASH_REMATCH[3]}"
          _report "$f" "$(( b_sr[bi] + bl - 3 ))" "$(( bc - 1 ))" FATAL shellcheck "$msg"
        done <<< "$sc_out"
      fi
    fi

    if [[ $_DO_ENV -eq 1 ]]; then
      while IFS= read -r rn; do
        [[ -z "$rn" ]] && continue
        _report "$f" "${c_sr[bi]}" "${c_sc[bi]}" WARN env "requires external env \$$rn"
      done < <(printf '%s' "$body" | _env_required)
    fi
  done
}

for _f in "${_FILES[@]}"; do lint_file "$_f"; done

printf '\nnixx-shellint: %d fatal, %d warn  (%d files)\n' "$_FATAL" "$_WARN" "${#_FILES[@]}" >&2
[[ $_FATAL -gt 0 ]] && exit 1
exit 0
