# A session or any JSONL file, read as raw lines, as preview lines: {lines: [[{text, role}]], cut}.
# $kind is claude, codex or generic. A line that is not JSON is skipped; a record of an unknown type shows nothing.

# nerd refuses a line over 512 cells: 256 characters fit even when every one is wide.
def cut: gsub("\t"; "    ") | .[0:256];
def lines($role): split("\n")[] | [{text: cut, role: $role}];
def firstline: if type == "string" then split("\n")[0]
  elif type == "array" then (map(select(type == "object" and (.type == "text" or .type == "input_text" or .type == "output_text")) | .text | strings) | first // "") | split("\n")[0]
  elif . == null then "" else tojson end;
def args: if type == "string" then (fromjson? // .) else . end;
def gist: args | if type == "object" then (.command // .cmd // .file_path // .path // .pattern // .query // .url // .description // .sql // tojson)
  else . end | if type == "string" then . elif type == "array" and all(.[]; type == "string") then join(" ") else tojson end;
# Every part as {who, line}: who is You or the agent for a turn's text, tool for anything else.
def say($who; $text): if ($text | startswith("<")) then {who: "tool", line: [{text: ($text | firstline | cut), role: "faint"}]}
  else ($text | lines("text") | {who: $who, line: .}) end;
def tool($name; $input): {who: "tool", line: [{text: ("  " + $name + ": " + ($input | gist | firstline) | cut), role: "muted"}]};
def result($out): {who: "tool", line: [{text: ("    " + ($out | firstline) | cut), role: "faint"}]};

def claude:
  # Text Claude Code puts in a user record itself (skills, compaction summaries) is not the user's: one faint line.
  if .type == "user" and (.isMeta == true or .isCompactSummary == true) then
    {who: "tool", line: [{text: ("  " + (.message.content | firstline) | cut), role: "faint"}]}
  elif .type == "user" then
    .message.content as $c
    | if ($c | type) == "string" then say("You"; $c)
      else $c[]? | select(type == "object") | if .type == "text" then say("You"; .text // "")
        elif .type == "tool_result" then result(.content)
        elif .type == "image" then {who: "tool", line: [{text: "  [image]", role: "faint"}]}
        else empty end
      end
  elif .type == "assistant" then .message.content[]? | select(type == "object")
    | if .type == "text" then say("Claude"; .text // "")
      elif .type == "tool_use" then tool(.name; .input)
      else empty end
  else empty end;

def codex:
  if .type == "response_item" then .payload as $p
    | if $p.type == "message" and ($p.role == "user" or $p.role == "assistant") then
        $p.content[]? | select(.type == "input_text" or .type == "output_text") | say(if $p.role == "user" then "You" else "Codex" end; .text)
      elif $p.type == "function_call" or $p.type == "custom_tool_call" or $p.type == "local_shell_call" then tool($p.name // "shell"; $p.arguments // $p.input // $p.action)
      elif ($p.type | tostring | endswith("_output")) then result($p.output)
      else empty end
  else empty end;

def generic: {who: "tool", line: [{text: (tojson | cut), role: "text"}]};

[ inputs | fromjson? | if $kind == "claude" then claude elif $kind == "codex" then codex else generic end ] as $parts
# A speaker's name opens each of their turns; a tool line keeps the turn it is in.
| [ foreach $parts[] as $x ({last: null, out: []};
      if $x.who == "tool" or $x.who == .last then .out = [$x.line]
      else .out = [[{text: "", role: "text"}], [{text: $x.who, role: (if $x.who == "You" then "accent" else "teal" end)}], $x.line] | .last = $x.who end;
      .out[]) ]
| if length > 2000 then {lines: .[-2000:], cut: true} else {lines: ., cut: false} end
