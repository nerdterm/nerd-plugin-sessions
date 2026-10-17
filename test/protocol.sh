#!/bin/sh
# Runs plugin.sh against a stand-in for nerd's socket and checks what it answers. macOS only (stat -f, nc -U).
set -u
cd "$(dirname "$0")/.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export HOME="$root/home" NERD_PLUGIN=sessions NERD_PLUGIN_DATA="$root/data" NERD_SOCKET="$root/s.sock"
mkdir -p "$HOME" "$NERD_PLUGIN_DATA"
dir=/work/app
proj="$HOME/.claude/projects/-work-app"
mkdir -p "$proj"
fails=0
check() {
    if eval "$2"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); fi
}

cp test/fixtures/claude.jsonl "$proj/small.jsonl"
printf '{"type":"custom-title","customTitle":"Renamed later","sessionId":"s1"}\n{"type":"last-prompt","lastPrompt":"Make the retry stop","sessionId":"s1"}\n' >> "$proj/small.jsonl"
wide=$(awk 'BEGIN { for (i = 0; i < 40; i++) printf "\xe6\xbc\xa2" }')
printf '{"type":"user","cwd":"%s","message":{"content":"%s"}}\n' "$dir" "$wide" > "$proj/wide.jsonl"
# A session big enough to still be rendering when the next request comes.
awk -v d="$dir" 'BEGIN { s = ""; for (i = 0; i < 300; i++) s = s "word "; for (n = 0; n < 15000; n++) printf "{\"type\":\"user\",\"cwd\":\"%s\",\"message\":{\"content\":\"%s\"}}\n", d, s }' > "$proj/big.jsonl"

# Events go out one per line with a pause after each; every message the plugin sends comes back on stdout.
events() {
    rm -f "$NERD_SOCKET"
    perl -MIO::Socket::UNIX -e '
        my ($path, @ev) = @ARGV;
        my $l = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $path, Listen => 1) or die "listen: $!";
        my $c = $l->accept or die "accept";
        $c->autoflush(1);
        my $connect = <$c>;
        if (my $pid = fork) {
            for (@ev) { my ($wait, $line) = split / /, $_, 2; select(undef, undef, undef, $wait); print $c "$line\n" }
            sleep 6; kill "TERM", $pid; close $c;
        } else { $| = 1; while (my $m = <$c>) { print $m } exit 0 }
    ' "$NERD_SOCKET" "$@" &
    server=$!
    sleep 0.3
    sh plugin.sh 2> "$root/stderr" &
    plugin=$!
    wait "$server"
    kill "$plugin" 2>/dev/null
    pkill -P "$plugin" 2>/dev/null
    wait "$plugin" 2>/dev/null
}

out=$(events \
    "0 {\"event\":\"preview_request\",\"req\":1,\"path\":\"$proj/big.jsonl\",\"cols\":80,\"rows\":20}" \
    "0.05 {\"event\":\"preview_request\",\"req\":2,\"path\":\"$proj/small.jsonl\",\"cols\":80,\"rows\":20}")
check "a newer preview request makes the older answer stale" '[ "$(printf "%s\n" "$out" | grep -c "\"req\":1,")" = 0 ] && [ "$(printf "%s\n" "$out" | grep -c "\"req\":2,")" = 1 ]'

out=$(events \
    "0 {\"event\":\"pane_opened\",\"pane\":1,\"cwd\":\"$dir\"}" \
    "0.1 {\"event\":\"panel_opened\",\"id\":\"sessions\",\"pane\":1}" \
    "3 {\"event\":\"panel_item\",\"panel\":\"sessions\",\"item\":\"$proj/big.jsonl\"}" \
    "0.05 {\"event\":\"panel_item\",\"panel\":\"sessions\",\"item\":\"back\"}")
first=$(printf '%s\n' "$out" | head -n 1)
last=$(printf '%s\n' "$out" | tail -n 1)
check "a row is named by the session's latest prompt" 'printf "%s" "$first" | jq -e ".Panel.kind == \"list\" and (.Panel.items | map(.label) | index(\"Make the retry stop\") != null)" > /dev/null'
check "a row says the title (a later rename winning), agent, branch, age and size" 'printf "%s" "$first" | jq -e ".Panel.items[] | select(.label == \"Make the retry stop\") | .detail | test(\"^Renamed later · claude · fix/login · .* · [0-9]+ (B|KB|MB)$\")" > /dev/null'
check "Back before the session came: the list is last, the session itself never shows" '[ "$(printf "%s" "$last" | jq -r .Panel.kind)" = list ] && ! printf "%s\n" "$out" | jq -e "select(.Panel.kind == \"detail\") | .Panel.lines | length > 1" > /dev/null'
check "a wide title is cut to fit 64 cells" 'printf "%s" "$first" | jq -e "[.Panel.items[].label | length] | max <= 60" > /dev/null'

out=$(events \
    "0 {\"event\":\"panel_item\",\"panel\":\"sessions\",\"item\":\"$proj/wide.jsonl\"}" \
    "0.5 this is not json")
check "a detail title is at most 32 characters" 'printf "%s\n" "$out" | jq -e "select(.Panel) | .Panel.title | length <= 32" > /dev/null'
check "opening says Loading at once, then shows the session" '[ "$(printf "%s\n" "$out" | head -n 1 | jq -r ".Panel.lines[0][0].text")" = "Loading…" ] && [ "$(printf "%s\n" "$out" | tail -n 1 | jq ".Panel.lines | length")" -gt 1 ]'
check "a line that is not an event repeats nothing" '[ "$(printf "%s\n" "$out" | grep -c "\"Panel\"")" = 2 ]'

tp="$HOME/.claude/projects/-tmp-demo"
mkdir -p "$tp"
printf '{"type":"user","cwd":"/tmp/demo","message":{"content":"Started under tmp"}}\n' > "$tp/t.jsonl"
out=$(events \
    "0 {\"event\":\"pane_opened\",\"pane\":2,\"cwd\":\"/private/tmp/demo\"}" \
    "0.1 {\"event\":\"panel_opened\",\"id\":\"sessions\",\"pane\":2}")
check "a session started in /tmp is listed from /private/tmp" 'printf "%s\n" "$out" | head -n 1 | jq -e ".Panel.items | map(.label) | index(\"Started under tmp\") != null" > /dev/null'

awk 'BEGIN { for (n = 0; n < 200000; n++) printf "[%d,\"row\",%d]\n", n, n * 2 }' > "$root/rows.jsonl"
out=$(events "0 {\"event\":\"preview_request\",\"req\":8,\"path\":\"$root/rows.jsonl\",\"cols\":80,\"rows\":20}")
check "records that are not objects: the last 2000, as any other JSONL" 'printf "%s\n" "$out" | jq -e "select(.Preview.req == 8) | (.Preview.lines | length) == 2000 and (.Preview.lines[-1][0].text | startswith(\"[199999,\"))" > /dev/null'

out=$(events "0 {\"event\":\"preview_request\",\"req\":7,\"path\":\"$root/missing.jsonl\",\"cols\":80,\"rows\":20}")
check "a missing file is answered, not ignored" 'printf "%s\n" "$out" | grep -q "cannot read missing.jsonl"'
check "nothing noisy on stderr" '! grep -q Terminated "$root/stderr"'

cp test/fixtures/log.jsonl "$root/log.jsonl"
ask() { printf '0 {"event":"preview_request","req":%s,"path":"%s","cols":80,"rows":20%s}' "$1" "$2" "${3:+,\"mode\":\"$3\"}"; }
for r in 21 22 23 24; do
    case $r in
        21) out=$(events "$(ask 21 "$root/log.jsonl")") ;;
        22) out=$(events "$(ask 22 "$root/log.jsonl" records)") ;;
        23) out=$(events "$(ask 23 "$proj/small.jsonl")") ;;
        24) out=$(events "$(ask 24 "$proj/small.jsonl" records)") ;;
    esac
    eval "p$r=\$(printf '%s\\n' \"\$out\" | grep '\"Preview\"' | tail -n 1)"
done
view() { printf '%s' "$1" | jq -r '.Preview.mode + " " + ([.Preview.modes[].label] | join(","))'; }
first() { printf '%s' "$1" | jq -r '.Preview.lines[0] | map(.text) | join("")'; }
check "any other JSONL: a table first, Table and Records offered" '[ "$(view "$p21")" = "table Table,Records" ] && first "$p21" | grep -q "^level  msg"'
check "asked for Records, it shows a record a line" '[ "$(view "$p22")" = "records Table,Records" ] && first "$p22" | grep -q "\"level\""'
check "a session: the conversation first, Conversation and Records offered" '[ "$(view "$p23")" = "chat Conversation,Records" ]'
check "asked for Records, a session shows its records as they are" '[ "$(view "$p24")" = "records Conversation,Records" ] && printf "%s" "$p24" | grep -q "custom-title"'


# Sizes and kinds of other JSONL, the cache, long names, a superseded render.
{ for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do printf '{"type":"file-history-snapshot","messageId":"m%s","snapshot":{}}\n' "$n"; done
  printf '{"type":"user","cwd":"/work/app","message":{"content":"After the snapshots"}}\n'; } > "$root/snap.jsonl"
awk 'BEGIN { for (n = 0; n < 5000; n++) printf "{\"n\":%d,\"msg\":\"row\"}\n", n }' > "$root/many.jsonl"
awk 'BEGIN { s = ""; for (i = 0; i < 10000; i++) s = s "x"; for (n = 0; n < 2500; n++) printf "{\"n\":%d,\"pad\":\"%s\"}\n", n, s }' > "$root/fat.jsonl"
awk 'BEGIN { s = ""; for (i = 0; i < 10000; i++) s = s "xxxxxxxxxx"; for (n = 0; n < 100; n++) t = t s; printf "{\"a\":\"%s\"}\n", t }' > "$root/oneline.jsonl"
out=$(events \
    "0 $(ask 31 "$root/snap.jsonl" | cut -c3-)" \
    "4 $(ask 32 "$root/many.jsonl" | cut -c3-)" \
    "4 $(ask 33 "$root/fat.jsonl" | cut -c3-)" \
    "4 $(ask 34 "$root/oneline.jsonl" | cut -c3-)")
pv() { printf '%s\n' "$out" | grep "\"req\":$1," | tail -n 1; }
check "a session that opens with snapshot records is a session" '[ "$(pv 31 | jq -r .Preview.mode)" = chat ]'
check "5000 records: at most 2000 lines, which nerd accepts, and said to be cut" '[ "$(pv 32 | jq ".Preview.lines | length")" -le 2000 ] && [ "$(pv 32 | jq .Preview.cut)" = true ]'
check "a 25 MB file of long records is read for its last 8 MB only, and said to be cut" '[ "$(pv 33 | jq ".Preview.lines | length")" -lt 1500 ] && [ "$(pv 33 | jq .Preview.cut)" = true ]'
check "a file with nothing readable in its last 8 MB says so" '[ "$(pv 34 | jq -r ".Preview.lines[0][0].text")" = "This file could not be read as JSON lines." ]'

# The plugin as nerd runs it, a group of its own, against a stand-in that sends "delay line" pairs; after $1 seconds
# (the group stopped first when $2 is yes) it finds the renders still running. A session over 64 MB renders for ~2.5 s.
cat "$proj/big.jsonl" "$proj/big.jsonl" "$proj/big.jsonl" > "$root/huge.jsonl"
solo() {
    wait_for=$1
    stop=$2
    shift 2
    rm -f "$NERD_SOCKET"
    perl -MIO::Socket::UNIX -e '
        my ($path, @ev) = @ARGV;
        my $l = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $path, Listen => 1) or die;
        my $c = $l->accept or die; $c->autoflush(1); my $x = <$c>;
        for (@ev) { my ($wait, $line) = split / /, $_, 2; select(undef, undef, undef, $wait); print $c "$line\n" }
        sleep 4;
    ' "$NERD_SOCKET" "$@" > /dev/null &
    sleep 0.3
    # From a copy under $root: only its renders are looked for and stopped, never another plugin's.
    mkdir -p "$root/plug" && cp plugin.sh *.jq "$root/plug/"
    (cd "$root/plug" && exec perl -e 'setpgrp(0, 0); exec "sh", "plugin.sh"') 2> /dev/null &
    group=$!
    sleep "$wait_for"
    [ "$stop" = yes ] && { kill -TERM -- "-$group"; sleep 0.3; }
    stray=$(pgrep -f "$root/plug/render.jq")
    [ -n "$stray" ] && kill $stray 2> /dev/null
    kill -TERM -- "-$group" 2> /dev/null
    wait 2> /dev/null
}
solo 1.3 no "0 $(ask 41 "$root/huge.jsonl" | cut -c3-)" "0.5 $(ask 42 "$root/log.jsonl" | cut -c3-)"
check "a superseded render is stopped down to its processes" '[ -z "$stray" ]'
solo 1 yes "0 $(ask 51 "$root/huge.jsonl" | cut -c3-)"
check "stopping the plugin's group leaves no render behind" '[ -z "$stray" ]'

ln -s /dev/zero "$root/zero.jsonl"
ln -s "$root/fat.jsonl" "$root/link.jsonl"
out=$(events \
    "0 $(ask 61 "$root/zero.jsonl" | cut -c3-)" \
    "4 $(ask 62 "$root/link.jsonl" | cut -c3-)")
check "a link to /dev/zero is refused at once, not read" 'printf "%s\n" "$out" | grep "\"req\":61," | grep -q "cannot read zero.jsonl"'
check "a symlinked file over 8 MB is read for its last 8 MB and said to be cut" 'printf "%s\n" "$out" | grep "\"req\":62," | jq -e ".Preview.cut == true and (.Preview.lines | length) < 1500" > /dev/null'

printf '{"type":"user","cwd":"%s","message":{"content":"SECRET-gone-prompt"}}\n' "$dir" > "$proj/gone.jsonl"
printf '{"type":"user","cwd":"%s","message":{"content":"red \\u001b[31m\\u0085flag"}}\n' "$dir" > "$proj/esc.jsonl"
mkdir -p "$HOME/.codex/sessions/2026"
sed 's/List the tests/UNRELATED-codex-prompt/' test/fixtures/codex.jsonl > "$HOME/.codex/sessions/2026/other.jsonl"
mkdir -p "$HOME/.claude/projects/-work-long"
{ printf '{"type":"user","cwd":"/work/long","gitBranch":"%s","message":{"content":"short prompt"}}\n' "$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "b" }')"
  printf '{"type":"custom-title","customTitle":"%s"}\n' "$(awk 'BEGIN { for (i = 0; i < 700; i++) printf "t" }')"; } > "$HOME/.claude/projects/-work-long/long.jsonl"
out=$(events \
    "0 {\"event\":\"pane_opened\",\"pane\":3,\"cwd\":\"$dir\"}" \
    "0.1 {\"event\":\"panel_opened\",\"id\":\"sessions\",\"pane\":3}" \
    "2 {\"event\":\"pane_opened\",\"pane\":4,\"cwd\":\"/work/long\"}" \
    "0.1 {\"event\":\"panel_opened\",\"id\":\"sessions\",\"pane\":4}")
check "a long rename and branch do not make nerd refuse the list" 'printf "%s\n" "$out" | tail -n 1 | jq -e "(.Panel.items | length) == 1 and (.Panel.items[0] | (.label + .detail | length) < 512)" > /dev/null'
check "the cache holds what was listed, without control characters" 'grep -q SECRET-gone-prompt "$NERD_PLUGIN_DATA/sessions.tsv" && grep -q UNRELATED-codex-prompt "$NERD_PLUGIN_DATA/sessions.tsv" && ! LC_ALL=C grep -q -e "$(printf "\033")" -e "$(printf "\302\205")" "$NERD_PLUGIN_DATA/sessions.tsv"'
rm -f "$proj/gone.jsonl" "$HOME/.codex/sessions/2026/other.jsonl"
out=$(events \
    "0 {\"event\":\"pane_opened\",\"pane\":4,\"cwd\":\"/work/long\"}" \
    "0.1 {\"event\":\"panel_opened\",\"id\":\"sessions\",\"pane\":4}")
check "a deleted session leaves nothing in the cache" '! grep -q -e SECRET-gone-prompt -e UNRELATED-codex-prompt "$NERD_PLUGIN_DATA/sessions.tsv"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
