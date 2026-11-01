# Commands

Every command runs from the repository root.

| Command | What it does |
|---|---|
| `nix flake check` | Runs the flake checks in the sandbox (see `testing.md`). |
| `nix fmt` | Formats the Nix files. |
| `nix build '.#cmake-purifier'` | Builds the `cmake-purifier` command. |
| `nix flake check --all-systems --no-build` | Evaluates the checks of both systems. |
| `tests/relock-fixtures.sh` | Relocks both fixtures. Needs the network. |
| `tests/interactive.sh` | Runs the interactive test outside the sandbox. |
