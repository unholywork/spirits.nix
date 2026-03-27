{
  description = "spirits - bridged networking VM test";

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
        name = "bridged";
        modules = [
          { spirit.networking.mode = "bridged"; }
        ];
        testScript = ./tests.sh;
        needsSudo = true;
      };
    in
    {
      packages.aarch64-darwin = {
        inherit (test) vm run-tests;
      };
    };
}
