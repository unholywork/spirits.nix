{
  description = "spirits - ephemeral disk test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    spirits.url = "../..";
    spirits.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      spirits,
      ...
    }:
    let
      mkTest = import ../lib/mk-test.nix { inherit nixpkgs spirits; };
      test = mkTest {
        name = "ephemeral-disk";
        modules = [
          {
            spirit.ephemeralDisk.enable = true;
          }
        ];
        testScript = ./tests.sh;
      };
    in
    {
      packages.aarch64-darwin = {
        inherit (test) vm run-tests;
      };
    };
}
