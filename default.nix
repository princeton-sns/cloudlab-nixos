{ cloudlabUser, manifestXml, addlSources ? [] }:

let
  krops = (import <nixpkgs> {}).fetchgit {
    url = https://cgit.krebsco.de/krops/;
    rev = "1.28.2";
    sha256 = "sha256-UToGr9L1ldZRDHuTJmiQUT4qMl2eTfH2pecUL8p7V6g=";
  };

  lib = import "${krops}/lib";
  pkgs = import "${krops}/pkgs" {};

  experimentConfig = import ./parseManifest.nix {
    inherit pkgs manifestXml;
  };

  source = nodeId: lib.evalSource [({
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

    miniond.git = {
      ref = "4e64c155869c71bddd045c415ce34a43ad8cac9c";
      url = https://github.com/lschuermann/miniond;
    };

    # Create a <nixos-config> path entry for the node config:
    nixos-config.file = toString ./node-config.nix;

    # Copy the XML manifest, such that it can be interpreted by the
    # nodes. Also create a file that indicates this node's ID:
    "manifest.xml".file = "${pkgs.writeText "manifest.xml" manifestXml}";
    node-id.file = "${pkgs.writeText "node-id.txt" nodeId}";

    # Copy the XML manifest parsing logic, such that it can be
    # imported in the node config:
    "parseManifest.nix".file = toString ./parseManifest.nix;

    # Include the bootstrap-deploy script, to determine certain
    # other node parameters before building:
    "bootstrap-deploy.sh".file = toString ./bootstrap-deploy.sh;
  } // (
    lib.foldl (acc: val: acc // val) {} (
      lib.map
        (sourceFn:
          if builtins.typeOf sourceFn == "lambda" then
            (sourceFn nodeId)
          else sourceFn)
        addlSources
    )
  ))];

  targets =
    builtins.map (nodeId: let
      nodeConfig = experimentConfig.nodes."${nodeId}";
    in {
      name = "deploy-${nodeId}";
      path = pkgs.krops.writeCommand "deploy-${nodeId}" {
        source = source nodeId;
        target = lib.mkTarget "${cloudlabUser}@${nodeConfig.hostname}.${nodeConfig.domain}" // {
          sudo = true;
          extraOptions = [ "-o" "StrictHostKeyChecking=no" ];
        };
        force = true;
        command = targetPath: ''
          sh ${targetPath}/bootstrap-deploy.sh "${targetPath}"
          nixos-rebuild -I "${targetPath}" switch
        '';
      };
    }) (builtins.attrNames experimentConfig.nodes);

in
  pkgs.linkFarm "cloudlab-experiment-deploy" (
    targets
    ++ [
      {
        name = "deploy-all";
        path = "${pkgs.writeShellScript "cloudlab-experiment-deploy-all.sh" ''
          #!${pkgs.bash}/bin/bash
          exec ${pkgs.multitail}/bin/multitail -s 3 ${
            lib.concatStringsSep " " (
              builtins.map (target:
                "-l '${target.path} || sleep inf'"
              ) targets
            )
          }
        ''}";
      }
      {
        name = "ssh-all";
        path = "${pkgs.writeShellScript "cloudlab-experiment-ssh-all.sh" ''
          #!${pkgs.bash}/bin/bash
          exec ${pkgs.multitail}/bin/multitail -s 3 ${
            lib.concatStringsSep " " (
              builtins.map (nodeConfig:
                "-l \"ssh ${cloudlabUser}@${nodeConfig.hostname}.${nodeConfig.domain} '$1' || sleep inf\""
              ) (builtins.attrValues experimentConfig.nodes)
            )
          }
        ''}";
      }
    ] ++ (
      builtins.map (nodeId: let
        nodeConfig = experimentConfig.nodes."${nodeId}";
      in {
        name = "ssh-${nodeId}";
        path = pkgs.writeShellScript "cloudlab-experiment-ssh-${nodeId}.sh" ''
          #!${pkgs.bash}/bin/bash
          exec ssh ${cloudlabUser}@${nodeConfig.hostname}.${nodeConfig.domain}
        '';
      }) (builtins.attrNames experimentConfig.nodes)
    )
  )
