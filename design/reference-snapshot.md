# reference/claude-code snapshot

`reference/claude-code/` is a local, gitignored mirror of
[anthropics/claude-code](https://github.com/anthropics/claude-code), used for
grepping hook payload shapes, agent/skill frontmatter fields, and plugin
examples without a network fetch. It is not part of the repo - nothing under
`reference/` is tracked or shipped.

It is a point-in-time snapshot, currently at tag `v2.1.263`, refreshed
2026-09-07. It is **not** authoritative: live docs at
[docs.claude.com](https://docs.claude.com) win on any disagreement, and the
installed CLI (`claude --version`) is the ground truth for current behavior.

Refresh it with:

```
just refresh-reference
```

This clones upstream at its latest release tag and mirrors it into
`reference/claude-code/` (excluding `.git` and `demo.gif`), creating the
directory if it doesn't exist yet. It prints the tag it landed on - update the
version/date above by hand afterward.
