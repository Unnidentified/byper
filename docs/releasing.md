# Releasing

## Version numbers

Semantic Versioning 2.0.0, written `vMAJOR.MINOR.PATCH`. The tag, the release
title, `CFBundleShortVersionString` in `src/app/Info.plist` and the
`BYPER_VERSION` default in `pkg/build_pkg.sh` are the same string. They used to
drift apart, so bump them in one commit.

- **MAJOR** for a redesign, or for anything that breaks an install path, a CLI
  flag, a settings key or the minimum macOS version.
- **MINOR** for new features that keep the old behaviour working.
- **PATCH** for fixes only.

## Pre-releases

`vX.Y.Z-beta.N` first, then `vX.Y.Z-rc.N` when the build is a candidate for the
final tag. The GitHub pre-release flag carries the status. The title is exactly
the tag, with no `(beta)` and no `-test` suffix, because the flag already says
it and the title is what people copy.

A pre-release never becomes Latest. If one is abandoned, leave it published and
do not reuse its number. The next attempt is `beta.N+1`.

## Branches

- `main` is always releasable. Everything on it has passed CI.
- `release/X.Y` is cut from `main` when a minor line still needs patches after
  the next minor has started. Fixes land there first and merge forward into
  `main`, never the other way round.
- Work branches are short lived and named `type/short-description`, where type
  is one of `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`. They are squash
  merged and deleted once merged.
- Tags are never moved after a release is published. The one exception is a
  mistake caught the same day, and then the release notes say what changed.

## Cutting a release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in
   `src/app/Info.plist`, and the `BYPER_VERSION` default in
   `pkg/build_pkg.sh`.
2. `make all`, then `./pkg/build_pkg.sh`. That writes `byper-installer.pkg` and
   `byper-installer.dmg`.
3. `shasum -a 256 byper-installer.pkg byper-installer.dmg > SHA256SUMS.txt`.
4. Tag the merge commit on `main`, not the branch commit:
   `git tag -a vX.Y.Z -m "vX.Y.Z"` and `git push origin vX.Y.Z`.
5. `gh release create vX.Y.Z` with the two assets and the sums. The title is the
   tag. Tick pre-release for a beta or an rc.
6. The notes follow the style below.

## Release notes

Write for someone deciding whether to install, not for someone reading the diff.

- Open with a sentence about what changed for them. Not a heading. A release
  that starts with "What's changed" every single time reads like a template.
- Three to six bullets, in plain language. No file paths, no symbol names, no
  bolded function names. Those belong in the commit, not the release.
- Say what was broken before, if something was broken. "Reconnecting the charger
  now brings bypass back" is better than "fixed reconcile guard".
- Keep the checksums if the release has them. Keep the Install section naming
  the two files.
- A pre-release says what it is previewing and what might still move.
- No em dashes, no emoji, no marketing adjectives.

## History

The releases before 3.0.0 did not follow the scheme above. Some carried `(beta)`
in the title, one carried a `-test` suffix, and one tag did not match its title.
They were renamed in place. The assets were not rebuilt, so the file names on
the older releases still carry the old version.

| Old | New |
|---|---|
| `v2.1.0 (beta)` | `v2.1.0-beta.1` |
| `v2.2.0 (beta)` | `v2.2.0-beta.1` |
| `v2.5.0-test` | `v3.0.0-beta.1` |
| `v2.2.5`, `v2.2.6`, `v2.2.7`, `v2.2.8`, `v2.2.9` | unchanged |
| `v2.3.0`, `v2.3.1`, `v2.4.0`, `v2.4.1` | unchanged |

`v2.5.0-test` was the first Liquid Glass build. It is a preview of the 3.0.0
redesign, so it became `v3.0.0-beta.1` rather than a 2.5.0 that never shipped.
