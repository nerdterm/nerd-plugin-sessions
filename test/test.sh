#!/bin/sh
# Renders the fixtures and checks what a reader would see. Needs jq. Exit 0 when every check holds.
set -u
cd "$(dirname "$0")/.."
fails=0
check() {
    if eval "$2"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); fi
}
text() { jq -nR -c --arg kind "$1" -f render.jq "test/fixtures/$2" | jq -r '.lines[] | map(.text) | join("")'; }
roles() { jq -nR -c --arg kind "$1" -f render.jq "test/fixtures/$2" | jq -r '.lines[] | map(.role + ":" + .text) | join("")'; }

c=$(text claude claude.jsonl)
check "a prompt shows under You" 'printf "%s\n" "$c" | grep -qx "You" && printf "%s\n" "$c" | grep -qx "It never stops."'
check "an answer shows under the agent's name" 'printf "%s\n" "$c" | grep -qx "Claude"'
check "thinking is hidden" '! printf "%s\n" "$c" | grep -q "secret reasoning"'
check "a tool call is one line with its gist" 'printf "%s\n" "$c" | grep -qx "  Bash: grep -n retry src/login.rs"'
check "a result shows its first line only" 'printf "%s\n" "$c" | grep -qx "    42: loop { retry(); }" && ! printf "%s\n" "$c" | grep -q "^43"'
check "a line that is not JSON is skipped" '! printf "%s\n" "$c" | grep -q "not json"'
check "a command wrapper is one faint line, not a prompt" 'roles claude claude.jsonl | grep -qx "faint:<command-name>/clear</command-name>"'
check "an unknown record shows nothing" '! printf "%s\n" "$c" | grep -q "brand-new"'
check "text Claude Code injects is one faint line, not the user's" 'roles claude claude.jsonl | grep -qx "faint:  Base directory for this skill: /x" && roles claude claude.jsonl | grep -qx "faint:  This session is being continued from a previous conversation." && ! printf "%s\n" "$c" | grep -q "line two of an injected skill"'
check "a part that is not an object, or null text, does not stop the view" 'printf "%s\n" "$c" | grep -qx "Fixed: it stops after three tries."'
check "a speaker's name opens their turn once" '[ "$(printf "%s\n" "$c" | grep -cx "Claude")" = 1 ]'

x=$(text codex codex.jsonl)
check "codex: context is faint, the prompt is the user's" 'printf "%s\n" "$x" | grep -qx "List the tests" && roles codex codex.jsonl | grep -q "^faint:<environment_context>"'
check "codex: a call and its output" 'printf "%s\n" "$x" | grep -qx "  shell: ls tests" && printf "%s\n" "$x" | grep -qx "    a.rs"'
check "codex: a tool output given as parts shows its text" 'printf "%s\n" "$x" | grep -qx "  apply_patch: \*\*\* Begin Patch" && printf "%s\n" "$x" | grep -qx "    Done: a.rs"'
check "codex: the answer under Codex" 'printf "%s\n" "$x" | grep -qx "Codex" && printf "%s\n" "$x" | grep -qx "Two tests: a.rs and b.rs."'

g=$(text generic log.jsonl)
check "any other JSONL: a record a line" '[ "$(printf "%s\n" "$g" | grep -c "\"level\"")" = 2 ]'

i=$(jq -nR -r -f info.jq test/fixtures/claude.jsonl)
check "info: agent, folder, branch, title" '[ "$i" = "$(printf "claude\t/work/app\tfix/login\tFix the login retry\tWhy does login retry forever?")" ]'
i=$(jq -nR -r -f info.jq test/fixtures/codex.jsonl)
check "info: codex title skips the injected context" '[ "$i" = "$(printf "codex\t/work/app/sub\tmain\t\tList the tests")" ]'


rows=$(awk 'BEGIN { for (n = 0; n < 2000; n++) printf "{\"n\":%d}\n", n }' | jq -nR -c -f table.jq)
check "a table is at most 2000 lines with its header, which nerd would refuse above" '[ "$(printf "%s" "$rows" | jq ".lines | length")" -le 2000 ] && [ "$(printf "%s" "$rows" | jq .cut)" = true ]'
b=$(awk 'BEGIN { s = ""; for (i = 0; i < 300; i++) s = s "b"; printf "{\"type\":\"user\",\"cwd\":\"/w\",\"gitBranch\":\"%s\",\"message\":{\"content\":\"hi\"}}\n", s }' | jq -nR -r -f info.jq | cut -f3)
check "info: a branch name is cut to 60 characters" '[ "${#b}" -le 60 ]'

long=$(mktemp)
awk 'BEGIN { s = ""; for (i = 0; i < 2000; i++) s = s "x"; for (n = 0; n < 2500; n++) printf "{\"type\":\"user\",\"message\":{\"content\":\"%s\"}}\n", s }' > "$long"
out=$(jq -nR -c --arg kind claude -f render.jq "$long")
rm -f "$long"
check "over 2000 lines: the newest 2000, said to be cut" '[ "$(printf "%s" "$out" | jq ".lines | length")" = 2000 ] && [ "$(printf "%s" "$out" | jq .cut)" = true ]'
check "no line over 256 characters" '[ "$(printf "%s" "$out" | jq "[.lines[][] .text | length] | max")" -le 256 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
