# CLAUDE.md

## Installing on Nautilus

When asked to install or set up this machine, follow INSTALL.md in order, using `./install.sh` for each phase. `./install.sh check` shows where things stand.

- Stop at every step marked **(you)** and ask the user. Those need a screen, a password, a browser login, or a decision.
- Never run `./install.sh das` until the user has named the exact disks, from a `/dev/disk/by-id/` listing you showed them. It erases them.
- Ask before layering packages with `rpm-ostree install`, adding kernel arguments, or changing BIOS-related settings.
- Don't read or print `.env` values. The user fills in the secrets.

## Commit messages

Format every commit message as a single-line summary header, a blank line, then one bullet per change:

```
Single line summary of the commit

- First change
- Second change
- etc.
```

- Each bullet fits on one line.
- No Claude attribution: no `Co-Authored-By: Claude` trailer or "Generated with Claude Code" line.
