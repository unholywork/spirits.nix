# Darwin module for running NixOS VMs via spirits.
# Set spirits.<name> to a NixOS configuration (result of nixpkgs.lib.nixosSystem).
{ spiritBin }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.spirits;
in
{
  options.spirits = lib.mkOption {
    type = lib.types.attrsOf lib.types.unspecified;
    default = { };
    description = "NixOS VM configurations, keyed by name. Each value is a nixosConfiguration.";
  };

  config = lib.mkIf (cfg != { }) {
    environment.systemPackages = lib.mapAttrsToList (
      name: nixosConfig:
      import ../../lib/make-vm.nix {
        name = "run-${name}";
        inherit nixosConfig spiritBin;
        hostPkgs = pkgs;
      }
    ) cfg;
  };
}
