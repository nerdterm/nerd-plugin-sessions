# A session's agent, folder, branch, title and first prompt, tab-separated, from its first records (raw lines).
def oneline: (split("\n")[0] // "") | gsub("\t"; " ") | .[0:80];
def prompt: if type == "string" then . elif type == "array" then (map(select(type == "object" and (.type == "text" or .type == "input_text")) | .text | strings) | first // "") else "" end;
[ limit(400; inputs | fromjson?) ] as $r
| (if any($r[]; .type == "session_meta") then "codex" else "claude" end) as $agent
| (first($r[] | .cwd // (select(.type == "session_meta") | .payload.cwd) | select(. != null)) // "") as $cwd
| (first($r[] | .gitBranch // (select(.type == "session_meta") | .payload.git.branch) | select(. != null and . != "")) // "") as $branch
| (first($r[] | select(.type == "custom-title") | .customTitle | select(. != null and . != "")) // "") as $title
| (first($r[] | (select(.type == "user" and .isMeta != true and .isCompactSummary != true) | .message.content), (select(.type == "response_item" and .payload.role == "user") | .payload.content)
             | prompt | select(. != "" and (startswith("<") | not))) // "") as $first
| [$agent, $cwd, ($branch | tostring | oneline | .[0:60]), ($title | oneline), ($first | oneline)] | @tsv
