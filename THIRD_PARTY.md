# Third-party components

## nxapi

- Project: https://github.com/samuelthomas2774/nxapi
- Upstream project homepage: https://gitlab.fancy.org.uk/samuel/nxapi
- Referenced commit: `47c9d35d9d51d33e62dd6d3733b616e0ad31b02b`
- License: AGPL-3.0-or-later
- Integration: Git submodule at `runtime/nxapi`

Game Presence Bridge does not vendor or copy nxapi's source files into its own source tree.
The Git submodule points to the upstream project at a tested commit. `Setup-Nxapi.cmd`
installs dependencies and compiles the CLI locally. The upstream license applies to nxapi
itself; see the license file in the initialized submodule.

## Node.js

Node.js is not bundled. Users install and run the system Node.js distribution under its
own license terms.

## Private runtime data

PSN credentials, Nintendo session data, npm cache, generated files, logs, and presence
outputs are local runtime data and are excluded from the main repository.
