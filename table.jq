# JSONL records (raw lines) as a table: a column per field, in the order fields first appear, a row per record.
# At most 1997 rows: with the header and rule nerd gets 2000 lines, its limit, and refuses more.
# Records that are not objects make no table: the output is then {lines: []} and the caller shows records instead.
def cell: if type == "string" then . elif . == null then "" else tojson end | gsub("[\t\n\r]"; " ");
def cut($n): if length > $n then .[0:$n - 1] + "…" else . end;
def pad($n): . + (" " * ($n - length));

[ inputs | fromjson? ] as $all
| ($all | length) as $count
| ($all[-1997:]) as $rows
| if ($rows | length) == 0 or ($rows | any(type != "object")) then {lines: []}
  else
    (reduce ($rows[] | keys_unsorted[]) as $k ([]; if index([$k]) then . else . + [$k] end)) as $fields
    | ($fields[0:8]) as $cols
    | [ $cols[] as $c | ([$c | length] + [$rows[] | .[$c] | cell | cut(24) | length]) | max ] as $width
    | def row($cells; $role): [{text: ([range(0; $cols | length) as $i | ($cells[$i] | cut(24) | pad($width[$i]))] | join("  ") | .[0:256]), role: $role}];
      {lines: (
         [ row($cols; "accent") ]
         + [ [{text: ([range(0; $cols | length) as $i | "-" * $width[$i]] | join("  ") | .[0:256]), role: "faint"}] ]
         + [ $rows[] as $r | row([$cols[] as $c | $r[$c] | cell]; "text") ]
         + (if ($fields | length) > 8 then [[{text: "\($fields | length - 8) more fields are not shown; Records shows them.", role: "faint"}]] else [] end)
       ),
       cut: ($count > 1997)}
  end
