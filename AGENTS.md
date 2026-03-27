Read README.md to get an understanding of the project.

After making changes, always run `nix run .#run-tests` to run the full test suite.

Each test lives in its own subdirectory under `tests/` with an independent `flake.nix`.
Shared test infrastructure (VM base config, runner, mk-test builder) lives in `tests/lib/`.
To run a specific test directly: `nix run ./tests/<name>#run-tests`.
To launch a test VM interactively (serial console): `nix run ./tests/<name>#vm`.
