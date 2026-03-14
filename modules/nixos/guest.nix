{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.spirit;
in
{
  options.spirit = {
    cpus = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Number of virtual CPUs.";
    };

    memoryMiB = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Memory in MiB.";
    };

    staticIP = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Static IP address for the guest (in 192.168.64.0/24). Uses DHCP when null.";
    };

    stateDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host directory for VM save/restore state files.";
    };

    hostKeys = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = "Path inside the guest where the key is mounted (e.g. from a virtiofs share).";
            };
            type = lib.mkOption {
              type = lib.types.enum [
                "ed25519"
                "rsa"
                "ecdsa"
              ];
              default = "ed25519";
              description = "SSH host key type.";
            };
          };
        }
      );
      default = [ ];
      description = "SSH host keys to install from virtiofs-mounted secrets. Disables auto-generation when set.";
    };

    disk = {
      enable = lib.mkEnableOption "persistent disk";
      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/vda";
        description = "Block device path for the persistent disk.";
      };
      fsType = lib.mkOption {
        type = lib.types.str;
        default = "ext4";
        description = "Filesystem type for the persistent disk.";
      };
      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/persist";
        description = "Mount point for the persistent disk.";
      };
      hostPath = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Path to the disk image on the host.";
      };
      hostSizeMiB = lib.mkOption {
        type = lib.types.int;
        default = 65536;
        description = "Disk image size in MiB (created on first run).";
      };
    };
  };

  config = lib.mkMerge [
    # Core guest configuration (always applied)
    {
      # Direct kernel boot — no bootloader needed
      boot.loader.grub.enable = false;

      # Kernel modules required for virtio devices
      boot.initrd.availableKernelModules = [
        "virtio_console"
        "virtiofs"
        "virtio_net"
        "virtio_pci"
        "overlay"
      ];

      # Serial console output
      boot.kernelParams = [ "console=hvc0" ];

      # Stateless root on tmpfs
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
        options = [
          "defaults"
          "size=2G"
          "mode=755"
        ];
      };

      # Mount host /nix/store via virtiofs as a lower layer, then overlay with tmpfs
      # so that Nix can chown /nix/store and write to the DB without modifying the host store.
      fileSystems."/nix/.ro-store" = {
        device = "nix-store";
        fsType = "virtiofs";
        options = [ "ro" ];
        neededForBoot = true;
      };

      fileSystems."/nix/.rw-store" = {
        device = "none";
        fsType = "tmpfs";
        options = [
          "mode=755"
          "size=512M"
        ];
        neededForBoot = true;
      };

      fileSystems."/nix/store" = {
        device = "overlay";
        fsType = "overlay";
        options = [
          "lowerdir=/nix/.ro-store"
          "upperdir=/nix/.rw-store/upper"
          "workdir=/nix/.rw-store/work"
        ];
        depends = [
          "/nix/.ro-store"
          "/nix/.rw-store"
        ];
        neededForBoot = true;
      };

      # Create overlay directories early in boot
      boot.initrd.postMountCommands = ''
        mkdir -p $targetRoot/nix/.rw-store/upper $targetRoot/nix/.rw-store/work
      '';

      # Register store paths in the guest Nix DB so the daemon can function.
      # Uses postBootCommands which runs in stage 2 boot before any systemd services,
      # avoiding ordering cycles with nix-daemon.socket.
      boot.postBootCommands = ''
        mkdir -p /nix/var/nix/db /nix/var/nix/gcroots /nix/var/nix/profiles /nix/var/nix/userpool
        mkdir -p /nix/var/nix/daemon-socket
        chmod 0755 /nix/var/nix/daemon-socket
        if [[ "$(cat /proc/cmdline)" =~ regInfo=([^ ]*) ]]; then
          ${config.nix.package.out}/bin/nix-store --load-db < "''${BASH_REMATCH[1]}"
        fi
      '';

      # Networking via systemd-networkd
      networking.useNetworkd = true;
      networking.useDHCP = false;
      systemd.network.enable = true;
    }

    # Networking: DHCP by default
    {
      systemd.network.networks."10-virtio" = {
        matchConfig.Name = "en* eth*";
        networkConfig.DHCP = lib.mkDefault "yes";
        dhcpV4Config.ClientIdentifier = lib.mkDefault "mac";
      };
    }

    # Static IP override
    (lib.mkIf (cfg.staticIP != null) {
      systemd.network.networks."10-virtio" = {
        networkConfig = {
          DHCP = lib.mkForce "no";
          Address = [ "${cfg.staticIP}/24" ];
          Gateway = [ "192.168.64.1" ];
          DNS = [ "192.168.64.1" ];
        };
      };
    })

    # SSH host keys from virtiofs-mounted secrets
    (lib.mkIf (cfg.hostKeys != [ ]) {
      # Disable automatic host key generation — we provide our own
      services.openssh.hostKeys = lib.mkForce [ ];

      systemd.services.install-ssh-host-keys = {
        description = "Install SSH host keys from host secrets";
        wantedBy = [ "sshd.service" ];
        before = [ "sshd.service" ];
        serviceConfig.Type = "oneshot";
        script = lib.concatStringsSep "\n" (
          map (
            key:
            let
              dest = "/etc/ssh/ssh_host_${key.type}_key";
            in
            ''
              mkdir -p /etc/ssh
              cp "${key.source}" "${dest}"
              chmod 600 "${dest}"
              if [ ! -f "${dest}.pub" ]; then
                ${pkgs.openssh}/bin/ssh-keygen -y -f "${dest}" > "${dest}.pub"
              fi
            ''
          ) cfg.hostKeys
        );
      };
    })

    # Persistent disk
    (lib.mkIf cfg.disk.enable {
      boot.initrd.availableKernelModules = [ "virtio_blk" ];

      fileSystems.${cfg.disk.mountPoint} = {
        device = cfg.disk.device;
        fsType = cfg.disk.fsType;
        autoFormat = true;
      };
    })
  ];
}
