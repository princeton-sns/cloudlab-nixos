# Minimal NixOS configuration for Emulab

{ config, pkgs, ... }: let
  nodeId = builtins.readFile <node-id>;

  experimentConfig = import <parseManifest.nix> {
    inherit pkgs;
    manifestXml = builtins.readFile <manifest.xml>;
  };
  nodeConfig = experimentConfig.nodes."${nodeId}";
  expLinkConfig = nodeConfig.experimentLinks."${nodeId}:eth1";
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    /etc/nixos/miniond/nixos/recommended-no-flakes.nix
  ];

  boot.loader.grub.enable = true;

  networking.useDHCP = true;

  networking.interfaces."${expLinkConfig.ifname}".ipv4.addresses = [{
    inherit (expLinkConfig.ipv4) address prefixLength;
  }];

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
  networking.firewall.enable = false;

  system.stateVersion = "23.05";
}
