#!/bin/sh
# sessions: the Claude Code and Codex sessions of a pane's folder in a panel, and any .jsonl in the preview.
# Each request runs in the background; a newer one of its kind stops it and makes its answer stale. Every message to
# nerd goes through one writer, which drops a stale answer, so two answers never interleave or arrive out of turn.
PATH=/usr/bin:/bin
here=$(pwd)
cd "$NERD_PLUGIN_DATA" || exit 1
rm -rf to-nerd msgs cwd out
rm -f cur.*
mkfifo to-nerd msgs
mkdir -p cwd out
LIST=200
tab=$(printf '\t')
# A title is at most 64 cells; 32 characters fit even when every one is wide.
TITLE=32

# Strips C0, DEL and C1 (UTF-8 U+0080-U+009F) controls, keeping tab and newline.
ctl() {
    LC_ALL=C tr -d '\000-\010\013-\037\177' | LC_ALL=C sed "s/$(printf '\302')[$(printf '\200')-$(printf '\237')]//g"
}

nojq() {
    printf '[[{"text":"sessions needs macOS 15 or later: it reads sessions with /usr/bin/jq","role":"warn"}]]'
}

# A finished message, handed to the writer by name with its job's kind and turn: a short line, written whole.
emit() {
    f=$(mktemp out/m.XXXXXX)
    cat > "$f"
    printf '%s %s %s\n' "$f" "$jkind" "$jturn" >&4
}

# Agent, folder, branch, title and latest prompt of a session, tab-separated. A later rename wins over the first
# title, and the latest prompt over the first one: that is what tells sessions of one name apart.
info() {
    f=$1
    i=$(head -c 4194304 "$f" 2>/dev/null | jq -nR -r -f "$here/info.jq" 2>/dev/null) || return 1
    # Read from the end: the newest rename and prompt are near it, and a long session is not read whole.
    renamed=$(tail -c 8388608 "$f" 2>/dev/null | tail -r 2>/dev/null | LC_ALL=C grep -m 1 -F '"type":"custom-title"' | jq -r '.customTitle // empty' 2>/dev/null)
    latest=$(tail -c 8388608 "$f" 2>/dev/null | tail -r 2>/dev/null | LC_ALL=C grep -m 1 -F '"type":"last-prompt"' | jq -r '.lastPrompt // empty' 2>/dev/null)
    i=$(printf '%s' "$i" | t=$(printf '%s' "$renamed" | tr '\t\n' '  ' | cut -c1-80) p=$(printf '%s' "$latest" | tr '\t\n' '  ' | cut -c1-80) \
        awk -F'\t' -v OFS='\t' '{ if (ENVIRON["t"] != "") $4 = ENVIRON["t"]; if (ENVIRON["p"] != "") $5 = ENVIRON["p"]; print }')
    # Control characters never reach the cache: it is a file a terminal may print.
    printf '%s\n' "$i" | ctl
}

# The newest sessions whose folder is $1 or inside it, as Panel items. One stat for every file, and a cache
# (sessions.tsv: modified, size, path, then info's fields) so only a session that changed is read again.
sessions() {
    # macOS: /tmp and /var are /private/tmp…; an agent records whichever spelling it was given.
    dir=$(printf '%s' "$1" | sed -E 's#^/private(/(tmp|var)(/|$))#\1#')
    enc=$(printf '%s' "$dir" | sed 's/[^A-Za-z0-9]/-/g')
    # Files of this request only: two lists at once never share one.
    w=$(mktemp -d out/l.XXXXXX)
    {
        for f in "$HOME/.claude/projects/$enc"*/*.jsonl "$HOME/.claude/projects/-private$enc"*/*.jsonl; do [ -f "$f" ] && printf '%s\0' "$f"; done
        [ -d "$HOME/.codex/sessions" ] && find "$HOME/.codex/sessions" -name '*.jsonl' -type f -print0
    } | xargs -0 stat -f "%m${tab}%z${tab}%N" 2>/dev/null > "$w/stamps"
    touch sessions.tsv
    # Known and unchanged: from the cache; the rest: read now.
    awk -F'\t' -v miss="$w/missing" 'FILENAME == ARGV[1] { c[$1 FS $2 FS $3] = $0; next } { k = $1 FS $2 FS $3; if (k in c) print c[k]; else print k > miss }' sessions.tsv "$w/stamps" > "$w/known"
    touch "$w/missing"
    while IFS="$tab" read -r m z f; do
        i=$(info "$f") || continue
        printf '%s\t%s\t%s\t%s\n' "$m" "$z" "$f" "$i"
    done < "$w/missing" >> "$w/known"
    # The cache: these sessions as they are now, every other folder's as they were; replaced whole, by rename.
    # A row whose session file is gone is dropped here, so no excerpt outlives its session.
    awk -F'\t' 'FILENAME == ARGV[1] { s[$3] = 1; next } !($3 in s) { print $3 }' "$w/stamps" sessions.tsv | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done > "$w/alive"
    awk -F'\t' 'FILENAME == ARGV[1] { a[$0] = 1; next } FILENAME == ARGV[2] { s[$3] = 1; next } !($3 in s) && ($3 in a)' "$w/alive" "$w/stamps" sessions.tsv | cat "$w/known" - | ctl > "$w/cache"
    mv "$w/cache" sessions.tsv
    d=$dir awk -F'\t' 'BEGIN { d = ENVIRON["d"] } { f = $5; if (f ~ /^\/private\/(tmp|var)(\/|$)/) f = substr(f, 9) } f == d || index(f, d "/") == 1' "$w/known" | sort -rn | head -n "$LIST" > "$w/rows"
    rm -rf "$w/stamps" "$w/missing" "$w/known"
    < "$w/rows" \
        jq -R -s -c --argjson now "$(date +%s)" '
            def ago: ($now - .) as $s | if $s < 120 then "just now" elif $s < 7200 then "\($s / 60 | floor) min ago"
                elif $s < 172800 then "\($s / 3600 | floor) h ago" else "\($s / 86400 | floor) days ago" end;
            def size: if . < 1024 then "\(.) B" elif . < 1048576 then "\(. / 1024 | floor) KB" else "\(. / 1048576 | floor) MB" end;
            # The latest prompt names the row; the title, which many sessions share, goes into the detail.
            [split("\n")[] | select(. != "") | split("\t") | (.[7] // "") as $p | (.[6] // "") as $t
             | {id: .[2], label: ((if $p != "" then $p elif $t != "" then $t else "untitled" end) | .[0:60]), opens: true,
                detail: ([(if $t != "" and $p != "" then $t else empty end), .[3], (if .[5] == "" then empty else .[5] end),
                          (.[0] | tonumber | ago), (.[1] | tonumber | size)] | join(" · "))}]'
    rm -rf "$w"
}

list() {
    dir=$1
    if [ -z "$dir" ]; then
        printf '{"Panel":{"id":"sessions","kind":"list","title":"Open Sessions from a pane'"'"'s menu","items":[]}}\n' | emit
        return
    fi
    printf '%s' "$dir" > listed
    items=$(sessions "$dir")
    [ -n "$items" ] || items='[]'
    printf '%s' "$items" | jq -c --arg d "$dir" --argjson n "$TITLE" '{Panel: {id: "sessions", kind: "list",
        title: ((if length == 0 then "No sessions in " else "Sessions in " end) + ($d | split("/") | last) | .[0:$n]), items: .}}' | emit
}

# The last $cap bytes of $f, a partial first line dropped.
tailb() {
    tail -c "$cap" "$f" | { [ "$size" -gt "$cap" ] && tail -n +2 || cat; }
}

# The readable form of a file in view $2, {lines, cut, modes, mode}: its kind found in its first records. A session
# offers Conversation and Records, any other JSONL Table (when its records are objects) and Records. An error is said.
render() {
    f=$1
    want=${2:-}
    # Bounded by bytes as well as lines: one line may be the whole file.
    size=$(stat -L -f %z "$f")
    kind=$(head -c 1048576 "$f" | head -n 400 | jq -nR -r '[inputs | fromjson? | objects] | if any(.[]; .type == "session_meta" or .type == "response_item") then "codex"
        elif any(.[]; (.type == "user" or .type == "assistant") and has("message")) then "claude" else "generic" end' 2>/dev/null)
    # Records that are not objects (arrays, numbers) leave the detection empty: they are any other JSONL too.
    case $kind in claude | codex) ;; *) kind=generic ;; esac
    if [ "$kind" = generic ]; then
        # One record a line: only the shown ones are read.
        modes='[{"id":"table","label":"Table"},{"id":"records","label":"Records"}]'
        mode=records
        cap=8388608
        [ "$want" = records ] || out=$(tailb | tail -n 2001 | jq -nR -c -f "$here/table.jq" 2>/dev/null)
        if [ -n "${out:-}" ] && [ "$(printf '%s' "$out" | jq '.lines | length')" -gt 0 ]; then
            mode=table
        else
            out=$(tailb | tail -n 2001 | jq -nR -c --arg kind generic -f "$here/render.jq" 2>/dev/null)
            # Records that are not objects have no table: one view is no choice.
            [ "$want" = records ] || modes='[]'
        fi
    else
        modes='[{"id":"chat","label":"Conversation"},{"id":"records","label":"Records"}]'
        mode=chat
        [ "$want" = records ] && { mode=records; kind=generic; }
        cap=67108864
        out=$(tailb | jq -nR -c --arg kind "$kind" -f "$here/render.jq" 2>/dev/null)
    fi
    [ "$(printf '%s' "$out" | jq '.lines | length' 2>/dev/null)" -gt 0 ] 2>/dev/null || { out='{"lines":[[{"text":"This file could not be read as JSON lines.","role":"warn"}]],"cut":false}'; modes='[]'; }
    printf '%s\n' "$out" | jq -c --argjson modes "$modes" --arg mode "$mode" --argjson big "$([ "$size" -gt "${cap:-0}" ] && echo true || echo false)" '. + {cut: (.cut or $big), modes: $modes, mode: (if ($modes | length) > 0 then $mode else "" end)}'
}

open() {
    f=$1
    back='{"id":"back","label":"Back to the sessions","opens":true}'
    if [ ! -f "$f" ]; then
        jq -cn --argjson back "$back" '{Panel: {id: "sessions", kind: "detail", title: "Gone", items: [$back],
            lines: [[{text: "That session is no longer there.", role: "warn"}]]}}' | emit
        return
    fi
    i=$(info "$f")
    title=$(printf '%s' "$i" | cut -f4)
    [ -n "$title" ] || title=$(printf '%s' "$i" | cut -f5)
    # At once, so the panel never shows the previous content while a long session is read.
    jq -cn --arg t "$title" --argjson n "$TITLE" --argjson back "$back" '{Panel: {id: "sessions", kind: "detail",
        title: ($t[0:$n] | if . == "" then "Session" else . end), items: [$back], lines: [[{text: "Loading…", role: "faint"}]]}}' | emit
    render "$f" | jq -c --arg t "$title" --argjson n "$TITLE" --argjson back "$back" '{Panel: {id: "sessions", kind: "detail",
        title: ($t[0:$n] | if . == "" then "Session" else . end), items: [$back],
        lines: (if .cut then [[{text: "Only the newest lines are shown.", role: "faint"}]] + .lines[1:] else .lines end)}}' | emit
}

preview() {
    req=$1
    f=$2
    mode=$3
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
        jq -cn --argjson req "$req" --arg n "${f##*/}" '{Preview: {req: $req, lines: [[{text: ("cannot read " + $n), role: "warn"}]], cut: false}}' | emit
        return
    fi
    render "$f" "$mode" | jq -c --argjson req "$req" '{Preview: {req: $req, lines: .lines, cut: .cut, modes: .modes, mode: .mode}}' | emit
}

# Starts $2… in the background as the next turn of job $1; the turn before is stopped and its answer is stale.
# Each job is a process group of its own (set -m), so the whole superseded render is stopped, not only its shell; the
# sandbox runs neither ps nor pgrep, but it allows kill on a group. The writer drops any answer that still arrives.
job() {
    jkind=$1
    shift
    jturn=$(( $(cat "cur.$jkind" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$jturn" > "cur.$jkind"
    eval "old=\${job_$jkind:-}"
    if [ -n "$old" ]; then
        kill -TERM -- "-$old" 2>/dev/null
        wait "$old" 2>/dev/null
        eval "job_$jkind="
    fi
    set -m
    "$@" &
    set +m
    eval "job_$jkind=$!"
}

# Jobs are groups of their own, so nerd's stop of the plugin's group does not reach them: stop them here.
stopjobs() {
    for g in ${job_panel:-} ${job_preview:-}; do kill -TERM -- "-$g" 2>/dev/null; done
}

nc -U "$NERD_SOCKET" < to-nerd | {
    trap 'stopjobs; exit' TERM
    printf '{"Connect":{"protocol":2,"role":"plugin","plugin":"%s","events":["pane_opened","pane_cwd","panel_opened","panel_item","preview_request"]}}\n' "$NERD_PLUGIN" >&3
    while read -r f k t; do
        [ "$(cat "cur.$k" 2>/dev/null)" = "$t" ] && cat "$f" >&3
        rm -f "$f"
    done < msgs &
    exec 4> msgs
    while IFS= read -r line; do
        if [ ! -x /usr/bin/jq ]; then
            req=$(printf '%s' "$line" | sed -n 's/.*"req":\([0-9]*\).*/\1/p')
            case $line in
                *'"event":"preview_request"'*) printf '{"Preview":{"req":%s,"lines":%s,"cut":false}}\n' "$req" "$(nojq)" >&3 ;;
                *'"event":"panel_'*) printf '{"Panel":{"id":"sessions","kind":"detail","title":"Sessions","items":[],"lines":%s}}\n' "$(nojq)" >&3 ;;
            esac
            continue
        fi
        vars=$(printf '%s' "$line" | jq -r 'def s: (. // "" | tostring);
            @sh "ev=\(.event | s) pane=\(.pane | s) dir=\(.cwd | s) item=\(.item | s) req=\(.req | s) path=\(.path | s) mode=\(.mode | s)"' 2>/dev/null)
        [ -n "$vars" ] || continue
        eval "$vars"
        case $ev in
            pane_opened | pane_cwd) [ -n "$pane" ] && printf '%s' "$dir" > "cwd/$pane" ;;
            panel_opened) job panel list "$( [ -n "$pane" ] && cat "cwd/$pane" 2>/dev/null)" ;;
            panel_item)
                if [ "$item" = back ]; then job panel list "$(cat listed 2>/dev/null)"; else job panel open "$item"; fi
                ;;
            preview_request) job preview preview "$req" "$path" "$mode" ;;
        esac
    done
    stopjobs
    exec 4>&-
} 3> to-nerd
