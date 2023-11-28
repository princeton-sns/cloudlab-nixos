{ config, pkgs, lib, ... }: let

  # ----- MANIFEST ---------------------------------------------------

  nodeId = builtins.readFile <node-id>;

  experimentConfig = import <parseManifest.nix> {
    inherit pkgs;
    manifestXml = builtins.readFile <manifest.xml>;
  };

  nodeConfig = experimentConfig.nodes."${nodeId}";

  # ----- NETWORKING -------------------------------------------------

  vlanLinkMatch = interfaceId: interface: {
    # We map all vlans to the same interface for now. At some point we
    # should consider allowing users to specify mappings to primary
    # interfaces.
    Name = builtins.readFile <experiment-link>;
  };

  vlanLinkName = interfaceId:
    "exp-v${builtins.elemAt (lib.splitString ":" interfaceId) 1}";

  # ----- DATASET ----------------------------------------------------

  dataset = let
    datasetInterface =
      lib.findSingle
        (link: link.dataset != null)
        null
        (abort "Multiple datasets on a single node not yet supported!")
        (builtins.attrValues nodeConfig.experimentInterfaces);
  in
    if datasetInterface != null then datasetInterface.dataset else null;

in {
  imports = [
    /etc/nixos/hardware-configuration.nix
    <miniond/nixos/recommended-no-flakes.nix>
    (import <experiment-config/cloudlab-node.nix> {
      inherit nodeId experimentConfig nodeConfig;
    })
  ];

  boot.loader.grub.enable = true;

  networking.hostName = nodeConfig.hostname;
  networking.domain = nodeConfig.domain;

  # Create /etc/resolv.conf entries for of the other nodes in this
  # experiment, which share a common link with this node.
  networking.extraHosts = let
    linkIds =
      builtins.map
        (interface: interface.linkId)
        (builtins.attrValues nodeConfig.experimentInterfaces);
    nodeIPs =
      lib.filter ({ ip, ...}: ip != null) (
        lib.mapAttrsToList
          (_: otherNodeConfig: let
            otherNodeIfConfig =
              lib.findFirst
                (interface: builtins.elem interface.linkId linkIds)
                null
                (builtins.attrValues otherNodeConfig.experimentInterfaces);
          in {
            hostAliases = [
              otherNodeConfig.hostname
              "${otherNodeConfig.hostname}.${otherNodeConfig.domain}"
            ];
            ip = if otherNodeIfConfig != null then otherNodeIfConfig.ipv4.address else null;
          })
          experimentConfig.nodes
      );
  in
    lib.concatStringsSep "\n" (
      builtins.map ({ ip, hostAliases }:
        "${ip} ${lib.concatStringsSep " " hostAliases}"
    ) nodeIPs
  );

  networking.useNetworkd = true;

  # Use DHCP for all interfaces not explicitly configured:
  networking.useDHCP = true;

  systemd.network.wait-online.enable = true;
  systemd.network.wait-online.anyInterface = true;

  systemd.network.networks = (

    # Generate network configs for each of the experiment links.
    lib.mapAttrs' (interfaceId: interface:
      lib.nameValuePair "01-experiment-link-${builtins.replaceStrings [":"] ["_"] interfaceId}" {
        matchConfig =
          if interface.vlanTag != null then {
            Name = vlanLinkName interfaceId;
          } else {
            # TODO!
          };

        networkConfig = {
          Address = "${interface.ipv4.address}/${builtins.toString interface.ipv4.prefixLength}";
        };
      }
    ) nodeConfig.experimentInterfaces

  ) // (

    # Generate network configs for each of the deduplicated backing
    # links that hold the various VLAN-based interfaces:
    (
      lib.foldlAttrs
        ({ i, networks }: interfaceId: interface: let
          existingNetworkDef =
            lib.findSingle
              (networkDefLabel:
                (vlanLinkMatch interfaceId interface) == networks."${networkDefLabel}".matchConfig)
              null
              (abort "Invariant violated: multiple network definitions with identical matchConfigs!")
              (lib.attrNames networks);
        in
          if existingNetworkDef != null then
            {
              networks = networks // {
                "${existingNetworkDef}" = networks."${existingNetworkDef}" // {
                  networkConfig = networks."${existingNetworkDef}".networkConfig // {
                    VLAN = networks."${existingNetworkDef}".networkConfig.VLAN ++ [
                      (vlanLinkName interfaceId)
                    ];
                  };
                };
              };
              i = i;
            }
          else
            {
              networks = networks // {
                "01-exp-vlink${builtins.toString i}" = {
                  matchConfig = vlanLinkMatch interfaceId interface;

                  networkConfig = {
                    VLAN = [ (vlanLinkName interfaceId) ];
                  };
                };
              };
              i = i + 1;
            }
        )
        { i = 0; networks = {}; }
        (lib.filterAttrs (_: interface: interface.vlanTag != null) nodeConfig.experimentInterfaces)
    )
      .networks

  );

  systemd.network.netdevs =
    # Generate netdev configs for any VLAN experiment links.
    lib.mapAttrs' (interfaceId: interface:
      lib.nameValuePair "01-experiment-link-${builtins.replaceStrings [":"] ["_"] interfaceId}" {
        netdevConfig = {
          Name = vlanLinkName interfaceId;
          Kind = "vlan";
        };

        vlanConfig = {
          Id = interface.vlanTag;
        };
      }
    ) (lib.filterAttrs (_: interface: interface.vlanTag != null) nodeConfig.experimentInterfaces);

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", ATTRS{model}=="iSCSI Disk      ", SYMLINK+="remoteDataset"
  '';

  services.openiscsi = lib.mkIf (dataset != null) {
    enable = true;
    name = "iqn.2023-11.${nodeConfig.domain}.${nodeConfig.hostname}:nixos";
    discoverPortal = dataset.serverIPv4;
    enableAutoLoginOut = true;
  };

  fileSystems."/remoteDataset" = lib.mkIf (dataset != null) {
    device = "/dev/remoteDataset";
    options = [ "_netdev" "x-systemd.requires=iscsi.service" "x-systemd.requires=systemd-networkd.service" ];
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
  ];

  # Clean up the filesystem when disk imaging is initiated
  hardware.emulab.enableLustrate = true;
  hardware.emulab.allowedImpurities = [
    # Impure paths that will go into the disk image
  ];

  services.openssh.enable = true;
  networking.firewall.enable = true;

  system.stateVersion = "23.05";
}
