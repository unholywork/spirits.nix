# Unholy Spirits

A nix-darwin module to declare ephemeral NixOS VMs, which run on Apple's Virtualization.framework.

Disclaimer: Code is AI generated.

## Requirements

A remote Linux builder is required to build the NixOS system. You can enable a VM-based builder in your nix-darwin config:

```nix
nix.linux-builder.enable = true;
```

## Usage

```nix
# flake.nix
{
  # <...>
  inputs.spirits.url = "github:unholywork/spirits.nix";
  spirits.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, nix-darwin, spirits }: {
    darwinConfigurations.my-mac = nix-darwin.lib.darwinSystem {
      modules = [
        spirits.darwinModules.default
        {
          spirits.my-vm = nixpkgs.lib.nixosSystem {
            system = "aarch64-linux";
            modules = [
              spirits.nixosModules.default
              {
                spirit = {
                  cpus = 4;
                  memoryMiB = 4096;
                };
              }
            ];
          };
        }
      ];
    };
  };
}
```

After switching, run `run-<vm name>` to launch the VM.

### Configuration options

```nix
{
  spirit = {
    cpus = 4; # default: 4
    memoryMiB = 4096; # default: 4096

    # Networking mode: "nat" (default) or "bridged"
    networking.mode = "nat";

    # NAT options:
    networking.nat.staticIP = "192.168.64.100"; # default: null (DHCP)

    # Bridged options (requires sudo; firewall is auto-enabled):
    # networking.mode = "bridged";
    # networking.bridged.interface = "en0"; # default: "en0"

    # Shared directories:
    sharedDirectories.projects = {
      hostPath = "/Users/me/projects";
      mountPoint = "/projects";
      readOnly = true; # default: false
    };

    # Ephemeral root disk — replaces tmpfs root with a disk image
    # that is recreated on each boot. Gives the nix store overlay
    # more space than the default 512M tmpfs.
    ephemeralDisk = {
      enable = true; # default: false
      sizeMiB = 8192; # default: 8192
    };

    # Attach a persistent disk image:
    disk = {
      enable = true; # default: false
      hostPath = "/Users/me/spirits/my-vm.img"; # default: ""
      hostSizeMiB = 65536; # default: 65536
      mountPoint = "/persist"; # default: "/persist"
      fsType = "ext4"; # default: "ext4"
    };

    # Install SSH host keys:
    hostKeys = [
      {
        source = "/run/host-secrets/ssh_host_key"; # needs to be mounted via a shared directory
        type = "ed25519";
      }
    ];
  };
}
```

## VM Control

While a VM is running, press **Ctrl+]** to pause it and open the control menu:

```
  spirits  (VM paused)
  ─────────────────────
  r / Enter / Esc  resume
  q                quit gracefully
  k                force kill
```

## Implementation Details

- By default, guests use a tmpfs root FS.
- A read-only squashfs containing the system closure is built on the host at switch time and attached to the guest as a virtio-blk disk. The guest mounts it at `/nix/.ro-store`.
- Guests create an overlay over the squashfs-backed `/nix/store` so `nix` commands can write to the store.
- The Nix DB is populated from `nix-path-registration` shipped inside the squashfs, so `nix` commands work inside the guest.
- With `ephemeralDisk.enable = true`, root switches to an ext4 disk image that is recreated on each boot. This reduces RAM demand and allows for larger nix stores.