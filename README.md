# sessions

A plugin for [nerd](https://github.com/nerdterm/nerd): read your Claude Code and Codex sessions without leaving the
terminal.

- **Sessions…** in a pane's menu lists the sessions started in that pane's folder or below it, newest first, with
  the agent, the git branch, how long ago and its size. Click one to read it in the same panel; **Back to the sessions**
  returns to the list.
- Selecting a `.jsonl` or `.ndjson` file in the tree previews it: a session as a conversation, any other file as a
  table, a column per field, when its records are objects. **v** (or **Next view** in the tree's menu) switches to
  **Records**, one record a line as it is written, and back; the view you chose stays for the next file. **w** wraps
  long lines.

A session reads as a conversation: your prompts under **You**, the agent's answers under its name, each tool call on
one muted line (`Bash: cargo test`) with the first line of its result under it. The agent's thinking is not shown,
and what the agent's tool put into the conversation itself (skills, summaries of earlier context) is one faint line,
not your prompt. Past 2000 lines, the newest 2000 are shown, and the view says so.

Risk level 0: it only shows things. It has no network and writes nothing outside its own data folder. Sessions can
hold whatever you pasted into them; this plugin draws them on your screen and nowhere else, with one exception: to open
the list fast it keeps, in its data folder (`sessions.tsv`), each session it has listed: folder, branch, title, and the
first and latest prompt cut to 80 characters, without control characters. That includes every Codex session on the
machine, whatever the pane's folder. A row is dropped the next time the list is opened after its session file is gone;
until then it stays, and it stays when the plugin is removed without its data (`nerd --plugin-remove sessions --data`
deletes it). While an answer is being sent it is also a file in `out/`, removed once sent.

`demo.cast` is a recording of it (asciinema), made with synthetic sessions.

## Install

In nerd: **Plugins…** in the main menu, then **sessions**. Or in a terminal:

```sh
nerd --plugin-add https://github.com/nerdterm/nerd-plugin-sessions
```

## Requirements

- nerd 0.8.0 or later.
- macOS 15 or later, for `/usr/bin/jq`. On an older macOS the plugin says so instead of showing sessions.
- Sessions in the default places: `~/.claude/projects` and `~/.codex/sessions`. A `CLAUDE_CONFIG_DIR` or `CODEX_HOME`
  set elsewhere is not seen: nerd does not pass those variables to plugins.

## Development

`sh test/test.sh` renders the fixtures in `test/fixtures` and checks the result; it needs `jq`.
`sh test/protocol.sh` runs the plugin against a stand-in for nerd's socket (macOS).
`nerd --plugin-check --catalog .` and `nerd --plugin-trial .` check the plugin as the catalog will.

## Licence

MIT, see [LICENSE](LICENSE).
