{ cloudlabUser }:

let
  krops = (import <nixpkgs> {}).fetchgit {
    url = https://cgit.krebsco.de/krops/;
    rev = "1.28.2";
    sha256 = "sha256-UToGr9L1ldZRDHuTJmiQUT4qMl2eTfH2pecUL8p7V6g=";
  };

  lib = import "${krops}/lib";
  pkgs = import "${krops}/pkgs" {};

  experimentConfig = import ./parseManifest.nix {
    inherit pkgs;
    manifestXml = builtins.readFile ./manifest.xml;
  };

  source = nodeId: lib.evalSource [{
    # If you want to build from git, uncomment this. Otherwise we'll
    # just use the pre-configured channel.
    #
    # TODO: pulling from git takes a really long time and a ton of
    # bandwidth. Presumably we don't want to do this on every machine.
    # Is there a more efficient, closer mirror for those channel
    # tarballs we can use?
    #
    # nixpkgs.git = {
    #   clean.exclude = ["/.version-suffix"];
    #   ref = "0c5678df521e1407884205fe3ce3cf1d7df297db";
    #   url = https://github.com/NixOS/nixpkgs;
    # };
    nixpkgs.symlink = "/nix/var/nix/profiles/per-user/root/channels/nixos/";

    # Deploy the ./config directory to the hosts
    config.file = toString ./config;

    # Create a <nixos-config> path entry for the node config:
    nixos-config.symlink = "config/node-config.nix";

    # Copy the XML manifest, such that it can be interpreted by the
    # nodes. Also create a file that indicates this node's ID:
    "manifest.xml".file = toString ./manifest.xml;
    node-id.file = "${pkgs.writeText "node-id.txt" nodeId}";

    # Copy the XML manifest parsing logic, such that it can be
    # imported in the node config:
    "parseManifest.nix".file = toString ./parseManifest.nix;
  }];

  targets =
    builtins.map (nodeId: let
      nodeConfig = experimentConfig.nodes."${nodeId}";
    in {
      name = "cloudlab-experiment-deploy-${nodeId}";
      path = pkgs.krops.writeDeploy "deploy" {
        source = source nodeId;
        target = lib.mkTarget "${cloudlabUser}@${nodeConfig.hostname}.${nodeConfig.domain}" // {
          sudo = true;
          extraOptions = [ "-o" "StrictHostKeyChecking=no" ];
        };
        force = true;
      };
    }) (builtins.attrNames experimentConfig.nodes);

in
  pkgs.linkFarm "cloudlab-experiment-deploy" (
    targets
    ++ [
      {
        name = "cloudlab-experiment-deploy-all";
        path = "${pkgs.writeShellScript "cloudlab-experiment-deploy-all.sh" ''
          #!${pkgs.bash}/bin/bash
          exec ${pkgs.multitail}/bin/multitail ${
            lib.concatStringsSep " " (
              builtins.map (target:
                "-l ${target.path}"
              ) targets
            )
          }
        ''}";
      }
    ]
  )
