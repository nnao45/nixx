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
# SC2154/SC2153: external env refs are validated by env-check, not shellcheck.
# SC2329: every body is wrapped in a never-called function so `local`/`return`
# are valid — that wrapper trips "function never invoked".
_DO_NIX=1 _DO_SC=1 _DO_ENV=1 _SC_EXCLUDE="SC2154,SC2153,SC2329"
_FIX=0 _DRYRUN=0
_FATAL=0 _WARN=0 _FIXED=0 _FIXFAIL=0
_PATHS=()
_EXCLUDE_PATHS=()

for _a in "$@"; do
  case "$_a" in
    --no-nix) _DO_NIX=0 ;;
    --no-shellcheck) _DO_SC=0 ;;
    --no-envcheck) _DO_ENV=0 ;;
    --fix) _FIX=1 ;;
    --dry-run) _DRYRUN=1 ;;
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
(with_expression) @with
(dollar_escape) @desc'

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
# range r2..r5 (0-based rows) c3..c6 (cols); strips ''…'', resolves ''$ ''', and
# expands nixx interpolation markers to placeholders so shellcheck/env see valid
# bash: @sh:q(x) → a quoted literal, @nix(x) → a bare word (its runtime form).
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
    | sed -E "s/@sh:q\([A-Za-z_][A-Za-z0-9_]*\)/'__nixx_shq__'/g; s/@nix\([A-Za-z_][A-Za-z0-9_]*\)/__nixx_val__/g" \
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

# ============================ --fix ============================
# read 0-based line ROW from FILE
_line_at() { awk -v r="$1" 'NR-1==r{print; exit}' "$2"; }

# extract the shell expansion starting at byte COL of LINE ($1=line $2=col)
_DB=$'\x24{'   # literal "${" without tripping SC2016
_exp_at() {
  local line="$1" col="$2" rest inner
  rest="${line:col}"
  if [[ "$rest" == "$_DB"* ]]; then
    inner="${rest#"$_DB"}"; inner="${inner%%\}*}"; printf '%s%s}' "$_DB" "$inner"
  elif [[ "$rest" =~ ^(\$[A-Za-z_][A-Za-z0-9_]*) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# safe to de-escape ''$VAR / ''${VAR} / ''${VAR:-simple} → drop the '' ?
_safe_deescape() {
  local e="$1"
  [[ "$e" =~ ^\$[A-Za-z_][A-Za-z0-9_]*$ ]] && return 0
  [[ "$e" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]] && return 0
  [[ "$e" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:[-=?+][A-Za-z0-9_./\ -]*\}$ ]] && return 0
  return 1
}

# does this ${...} text carry a shell-only / parse-wall char ?
_is_parsewall() {
  local e="$1"
  [[ "$e" == *'#'* ]] && return 0
  [[ "$e" == *'^'* ]] && return 0
  [[ "$e" == *'%'* ]] && return 0
  [[ "$e" == *','* ]] && return 0
  [[ "$e" =~ \[[@*-] ]] && return 0   # ${ARR[@]} ${ARR[*]} ${ARR[-1]}
  return 1
}

# count ERROR nodes tree-sitter-nix sees in FILE
_count_errors() {
  local o
  o=$(tree-sitter query --lib-path "$NIXX_TSN_PARSER" --lang-name nix \
      <(printf '(ERROR) @e') "$1" 2>/dev/null) || return 0
  printf '%s' "$o" | grep -c 'capture:'
}

# apply edits (parallel arrays _er/_ec/_edel/_eins) to FILE → stdout new content.
# edits are single-line; applied right-to-left within each row.
_apply_edits() {
  local f="$1" n=${#_er[@]} i row col del ins
  local -a lines=()
  mapfile -t lines < "$f"
  # process rows that have edits; within a row, descending col
  local -a order=()
  for (( i=0; i<n; i++ )); do order+=("$i"); done
  # simple selection: sort indices by (row asc, col desc)
  local a b tmp
  for (( a=0; a<n; a++ )); do for (( b=a+1; b<n; b++ )); do
    if (( _er[order[b]] < _er[order[a]] )) || \
       (( _er[order[b]] == _er[order[a]] && _ec[order[b]] > _ec[order[a]] )); then
      tmp=${order[a]}; order[a]=${order[b]}; order[b]=$tmp
    fi
  done; done
  for i in "${order[@]}"; do
    row=${_er[i]}; col=${_ec[i]}; del=${_edel[i]}; ins=${_eins[i]}
    lines[row]="${lines[row]:0:col}${ins}${lines[row]:col+del}"
  done
  printf '%s\n' "${lines[@]}"
}

fix_file() {
  local f="$1" out line name sr sc er ec txt
  out=$(tree-sitter query --lib-path "$NIXX_TSN_PARSER" --lang-name nix \
        <(printf '%s' "$_NIX_Q") "$f" 2>/dev/null) || return 0
  local -a c_sr=() c_sc=() c_er=() c_ec=() c_fn=()
  local -a b_sr=() b_sc=() b_er=() b_ec=()
  local -a w_sr=() w_sc=() w_er=() w_ec=()
  local -a i_sr=() i_sc=() i_er=() i_ec=() i_tx=()
  local -a e_sr=() e_sc=() e_er=() e_ec=()
  local -a d_sr=() d_sc=() d_er=() d_ec=()
  while IFS= read -r line; do
    [[ "$line" =~ $_CAP_RE ]] || continue
    name="${BASH_REMATCH[2]}"; sr="${BASH_REMATCH[3]}"; sc="${BASH_REMATCH[4]}"
    er="${BASH_REMATCH[5]}"; ec="${BASH_REMATCH[6]}"
    txt=""; [[ "$line" =~ $_TXT_RE ]] && txt="${BASH_REMATCH[1]}"
    case "$name" in
      call) c_sr+=("$sr"); c_sc+=("$sc"); c_er+=("$er"); c_ec+=("$ec"); c_fn+=("")
            b_sr+=("-1"); b_sc+=("-1"); b_er+=("-1"); b_ec+=("-1") ;;
      fn)   c_fn[${#c_fn[@]} - 1]="$txt" ;;
      body) local _bx=$(( ${#b_sr[@]} - 1 ))
            b_sr[_bx]="$sr"; b_sc[_bx]="$sc"; b_er[_bx]="$er"; b_ec[_bx]="$ec" ;;
      with) w_sr+=("$sr"); w_sc+=("$sc"); w_er+=("$er"); w_ec+=("$ec") ;;
      interp) i_sr+=("$sr"); i_sc+=("$sc"); i_er+=("$er"); i_ec+=("$ec"); i_tx+=("$txt") ;;
      err)  e_sr+=("$sr"); e_sc+=("$sc"); e_er+=("$er"); e_ec+=("$ec") ;;
      desc) d_sr+=("$sr"); d_sc+=("$sc"); d_er+=("$er"); d_ec+=("$ec") ;;
    esac
  done <<< "$out"

  local nb=${#c_sr[@]} ni=${#i_sr[@]} ne=${#e_sr[@]} nw=${#w_sr[@]} nd=${#d_sr[@]}
  local bi ii ei wi di in_b has_with exp lr
  _er=() _ec=() _edel=() _eins=()   # edit arrays (row col del ins)

  _block_of() {  # which ctor block body contains range $1..$4 ? → sets REPLY=index|-1
    local r=-1 b
    for (( b=0; b<nb; b++ )); do
      _is_ctor "${c_fn[b]}" || continue
      if _contains "${b_sr[b]}" "${b_sc[b]}" "${b_er[b]}" "${b_ec[b]}" "$1" "$2" "$3" "$4"; then r=$b; break; fi
    done
    REPLY=$r
  }
  _block_has_with() {  # block index $1 enclosed by a with ?
    local b=$1 w
    for (( w=0; w<nw; w++ )); do
      _contains "${w_sr[w]}" "${w_sc[w]}" "${w_er[w]}" "${w_ec[w]}" \
                "${c_sr[b]}" "${c_sc[b]}" "${c_er[b]}" "${c_ec[b]}" && return 0
    done
    return 1
  }

  # (1) de-escape: ''$VAR / ''${safe} inside a with-covered ctor block → drop ''
  for (( di=0; di<nd; di++ )); do
    _block_of "${d_sr[di]}" "${d_sc[di]}" "${d_er[di]}" "${d_ec[di]}"; in_b=$REPLY
    [[ $in_b -lt 0 ]] && continue
    _block_has_with "$in_b" || continue
    lr=$(_line_at "${d_sr[di]}" "$f")
    exp=$(_exp_at "$lr" "${d_ec[di]}")          # text right after the ''
    [[ -z "$exp" ]] && continue
    _safe_deescape "$exp" || continue
    _er+=("${d_sr[di]}"); _ec+=("${d_sc[di]}"); _edel+=(2); _eins+=("")
  done

  # (2) escape interps: a parse-wall form (always invalid Nix → escape), or a
  # bare ${VAR} in a block with no enclosing `with`. We key off the interp's OWN
  # text, not mere err-overlap — a `#` cascade can drape an ERROR over an innocent
  # neighbouring ${pkgs.foo} interpolation, which must stay untouched.
  for (( ii=0; ii<ni; ii++ )); do
    _block_of "${i_sr[ii]}" "${i_sc[ii]}" "${i_er[ii]}" "${i_ec[ii]}"; in_b=$REPLY
    [[ $in_b -lt 0 ]] && continue
    local do_esc=0
    if _is_parsewall "${i_tx[ii]}"; then
      do_esc=1
    elif [[ "${i_tx[ii]}" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]]; then
      _block_has_with "$in_b" || do_esc=1
    fi
    [[ $do_esc -eq 1 ]] && { _er+=("${i_sr[ii]}"); _ec+=("${i_sc[ii]}"); _edel+=(0); _eins+=("''"); }
  done

  # (3) escape #-cascade: raw-scan err rows for unescaped ${parse-wall}. No block
  # gate — a `#` cascade destroys the block node, so containment can't be checked;
  # only parse-wall forms are touched and the post-fix verify reverts any misfire.
  for (( ei=0; ei<ne; ei++ )); do
    local r c ln off pre mexp
    for (( r=e_sr[ei]; r<=e_er[ei]; r++ )); do
      ln=$(_line_at "$r" "$f")
      c=0
      while [[ "${ln:c}" == *"$_DB"* ]]; do
        pre="${ln:c}"; off="${pre%%"$_DB"*}"; c=$(( c + ${#off} ))
        # skip if preceded by ' (already ''-escaped)
        if [[ $c -gt 0 && "${ln:c-1:1}" == "'" ]]; then c=$(( c + 2 )); continue; fi
        mexp=$(_exp_at "$ln" "$c")
        if [[ -n "$mexp" ]] && _is_parsewall "$mexp"; then
          _er+=("$r"); _ec+=("$c"); _edel+=(0); _eins+=("''")
        fi
        c=$(( c + 2 ))
      done
    done
  done

  local nedit=${#_er[@]}
  [[ $nedit -eq 0 ]] && return 0

  # dedup edits by (row,col)
  local -a u_r=() u_c=() u_d=() u_i=() seen=""
  local k key
  for (( k=0; k<nedit; k++ )); do
    key="${_er[k]}:${_ec[k]}"
    case " $seen " in *" $key "*) continue ;; esac
    seen+=" $key"
    u_r+=("${_er[k]}"); u_c+=("${_ec[k]}"); u_d+=("${_edel[k]}"); u_i+=("${_eins[k]}")
  done
  _er=("${u_r[@]}"); _ec=("${u_c[@]}"); _edel=("${u_d[@]}"); _eins=("${u_i[@]}")
  nedit=${#_er[@]}

  local newc; newc=$(_apply_edits "$f")   # command sub strips the trailing \n; re-add on write
  if [[ $_DRYRUN -eq 1 ]]; then
    printf '=== %s (%d fix%s) ===\n' "$f" "$nedit" "$([[ $nedit -eq 1 ]] || printf es)"
    diff -u "$f" <(printf '%s\n' "$newc") || true
    _FIXED=$(( _FIXED + nedit ))
    return 0
  fi
  # write, then verify: a fix must leave the file ERROR-free, else revert
  local bak; bak=$(mktemp); cp "$f" "$bak"
  printf '%s\n' "$newc" > "$f"
  if [[ "$(_count_errors "$f")" -ne 0 ]]; then
    cp "$bak" "$f"; rm -f "$bak"
    printf 'nixx-shellint: %s — could not auto-fix safely (reverted)\n' "$f" >&2
    _FIXFAIL=$(( _FIXFAIL + 1 ))
    return 0
  fi
  rm -f "$bak"
  printf 'fixed %s (%d edit%s)\n' "$f" "$nedit" "$([[ $nedit -eq 1 ]] || printf s)"
  _FIXED=$(( _FIXED + nedit ))
}

if [[ $_FIX -eq 1 ]]; then
  for _f in "${_FILES[@]}"; do fix_file "$_f"; done
  if [[ $_DRYRUN -eq 1 ]]; then
    printf '\nnixx-shellint --fix --dry-run: %d edit(s) across %d files\n' "$_FIXED" "${#_FILES[@]}" >&2
  else
    printf '\nnixx-shellint --fix: %d edit(s) applied, %d file(s) reverted\n' "$_FIXED" "$_FIXFAIL" >&2
  fi
  [[ $_FIXFAIL -gt 0 ]] && exit 1
  exit 0
fi

for _f in "${_FILES[@]}"; do lint_file "$_f"; done

printf '\nnixx-shellint: %d fatal, %d warn  (%d files)\n' "$_FATAL" "$_WARN" "${#_FILES[@]}" >&2
[[ $_FATAL -gt 0 ]] && exit 1
exit 0
