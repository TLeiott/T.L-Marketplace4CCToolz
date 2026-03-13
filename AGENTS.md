# Repository Notes

## Versioning Rule

Do not push changed marketplace or plugin content under an unchanged version.

If a change is intended to be pushed and affects distributed behavior or content, bump the version at the same time. At minimum, increment the patch version.

This applies in particular to changes in:

- `plugins/T.L-AutoDevelop/**`
- `plugins/T.L-AutoDevelop-Pro/**`
- `.claude-plugin/marketplace.json`

Keep version fields in sync for every affected plugin:

- `plugins/T.L-AutoDevelop/.claude-plugin/plugin.json`
- `plugins/T.L-AutoDevelop-Pro/.claude-plugin/plugin.json`
- matching plugin entries in `.claude-plugin/marketplace.json`

Practical rule:

- change only `T.L-AutoDevelop` -> bump `T.L-AutoDevelop` in both manifest locations
- change only `T.L-AutoDevelop-Pro` -> bump `T.L-AutoDevelop-Pro` in both manifest locations
- change shared behavior, marketplace packaging, or both plugins -> bump both plugins

Reason: Claude plugin caches can keep older copies when different content is published under the same version number.
