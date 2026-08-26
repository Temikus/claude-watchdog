# Security Policy

## Supported versions

Only the latest released version of claude-watchdog receives security fixes. Please upgrade before reporting an issue against an older release.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No |

## Reporting a vulnerability

Please report security issues privately through [GitHub's private vulnerability reporting](https://github.com/Temikus/claude-watchdog/security/advisories/new) rather than opening a public issue.

Include, where you can:

1. A description of the issue and its impact.
2. Steps to reproduce, or a proof of concept.
3. The plugin version and your Claude Code version.
4. Any suggested fix or mitigation.

This is a hobby project maintained in spare time, so expect an acknowledgement within a week and a fix timeline agreed with you once the report is triaged. Please give a reasonable window for a fix before disclosing publicly.

## Scope

claude-watchdog is a Claude Code plugin. It runs hook scripts (`hooks/*.mjs`) on your machine under your own Claude Code process, reads session transcripts, writes condensed copies to disk, and spawns an in-session analyzer subagent. It makes no external network calls and uses no API keys of its own.

In scope:

- Arbitrary code execution or command injection via hook scripts or transcript content.
- Path traversal or unintended file writes from transcript handling or the configured storage path.
- Leaking transcript contents outside the local machine.
- Privilege or permission escalation beyond what the hooks are declared to need.

Out of scope:

- Vulnerabilities in Claude Code itself - report those to Anthropic.
- The sensitivity of what a session transcript contains. Condensed transcripts are written under `.claude/tmp/claude-watchdog/` (or the global plugin data path) in plaintext by design; keep `.claude/` in `.gitignore` and treat those files as you would any other local session data.
- Findings that require an attacker to already have write access to your repository or your Claude Code configuration.
