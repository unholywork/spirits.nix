# Common NixOS module for test VMs.
# Provides SSH access and boot-ready signalling.
{ sshPubKey }:
{ pkgs, ... }:
{
  spirit = {
    cpus = 4;
    memoryMiB = 4096;
    networking.nat.staticIP = "192.168.64.200";
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };
  users.users.root = {
    password = "root";
    openssh.authorizedKeys.keys = [ sshPubKey ];
  };

  systemd.services.test-ready = {
    description = "Signal test readiness on serial console";
    after = [
      "multi-user.target"
      "sshd.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "test-ready" ''
        IP=$(${pkgs.iproute2}/bin/ip -4 -o addr show scope global | ${pkgs.gawk}/bin/awk '{print $4}' | cut -d/ -f1 | head -1)
        echo "SPIRITS_TEST_READY ip=$IP" > /dev/hvc0
      '';
    };
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    curl
    git
    nix
  ];

  system.stateVersion = "24.11";
}
