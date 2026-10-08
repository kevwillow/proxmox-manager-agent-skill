# Contributing

Bug reports and PRs welcome. Open an issue first for any non-trivial
change so we can agree on direction.

## What to contribute

- **Pitfall fixes.** Spent an hour debugging something that wasn't in
  the SKILL.md? Add it to "Common Pitfalls." PVE 9.x has many.
- **New `qm create` / `pct create` recipes.** Tested recipes for distros
  not yet covered (Fedora, Rocky, Alma, Arch, NixOS, etc.).
- **New scripts.** Workflows that come up repeatedly. Wrap them in a
  script under `scripts/`.
- **Reference material.** Anything you'd want a fresh agent to know
  before working on your specific PVE setup.

## What NOT to contribute

- Speculative features (commands that exist in PVE 8 but are removed in
  9, "maybe useful someday" tooling).
- Vendor-specific one-offs that only work on your hardware.
- Recipes for non-Proxmox virtualization (KVM, Xen, ESXi) — different
  problem domain.

## Style

- SKILL.md is the source of truth. Scripts and references support it.
- Reference files start with a one-paragraph summary of when to use them.
- Scripts are POSIX-leaning bash with `set -euo pipefail`. They print
  what they're doing before doing it.
- Pitfalls are numbered, named, and have a "fix" line.
- No marketing language. No "easily" or "simply" — if it weren't easy,
  it wouldn't be in the skill.

## Testing

Before submitting a PR:

1. Run `./install.sh --agent hermes` and verify the skill loads.
2. Run `bash tests/pve-api.test.sh` and `shellcheck -x -S warning scripts/*.sh templates/*.sh install.sh`.
3. Run any new script on a real PVE host (PVE 9.x if possible).
4. Update CHANGELOG.md with the entry under "Unreleased."
5. Update SKILL.md's reference/script sections to mention the new files.

## Pull request

- One logical change per PR.
- PR title in imperative mood ("Add Proxmox 9.x DNS pitfall," not
  "Added new pitfall about DNS").
- PR description explains the WHY. What changed is in the diff.
- Squash commits before merging.
