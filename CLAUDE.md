# TackleMaster

## Data

- `Data.lua` is generated: `python tools/gen_data.py [build]` (defaults to the newest WoW Forever build on wago.tools). Rerun it when Forever patches, commit the result. Pole fishing bonuses are the one hand-kept list, in the generator.

## Taint

- Never call Blizzard UI code (panels, frames, their functions) from this add-on: on Forever, Blizzard code run from an add-on is tainted and then fails on secret values (Angleur's errors came from its button opening the character panel).

## Releases

- Every release has a changelog. `CHANGELOG.md` holds only the version being released, rewritten before each tag. The packager (`manual-changelog` in `.pkgmeta`) puts it in the GitHub release and on CurseForge.
- Brief and terse: what changed since the previous version, one line per change, as a player sees it. No AI-sounding phrasing, no filler, no Claude attribution.
- Flow: rewrite `CHANGELOG.md`, commit, `git tag X.Y.Z`, push the branch and the tag.
