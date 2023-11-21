{ pkgs ? import <nixpkgs> {}, manifestXml }: let
  lib = pkgs.lib;

  pow = base: exp:
    if exp == 0 then 1 else base * (pow base (exp - 1));

  prefixLengthFromIPv4Netmask = netmask: let
    netmaskOctet = prefixLength: octet:
      builtins.toString (256 - (pow 2 (8 - (lib.max 0 (lib.min 8 (prefixLength - (octet * 8)))))));

    netmaskLookups = lib.listToAttrs (
      builtins.map (prefixLength:
        lib.nameValuePair (
          "${netmaskOctet prefixLength 0}"
          + ".${netmaskOctet prefixLength 1}"
          + ".${netmaskOctet prefixLength 2}"
          + ".${netmaskOctet prefixLength 3}"
        ) prefixLength
      ) (lib.range 0 32)
    );
  in
    netmaskLookups."${netmask}";

  # Lookup table from node-type to experiment link interface name.
  nodeExperimentLink0 = {
    "m510" = "eno1d1";
  };

  # First, convert the manifest XML to JSON, and import it into a Nix
  # attribute set. We can then traverse it and build a node map.
  manifestJson = pkgs.runCommand "manifest.json" {} ''
    cat ${pkgs.writeText "manifest.xml" manifestXml} \
      | ${pkgs.python3Packages.xmljson}/bin/xml2json -d badgerfish > $out
  '';
  manifest = builtins.fromJSON (builtins.readFile "${manifestJson}");

  # Whether the parsed XML represents a given node as a list or not
  # depends on whether there are multiple occurrences of that tag. We
  # want to be generic over, e.g., the number of interfaces, and thus
  # should always traverse such lists, even if they have one
  # element. This function puts all non-list types into a singleton
  # list:
  ensureList = val:
    if builtins.typeOf val == "list" then
      val
    else
      lib.singleton val;

  # XML namespaces used throughout the manifest.
  xmlnsRspec = "http://www.geni.net/resources/rspec/3";
  xmlnsEmulab = "http://www.protogeni.net/resources/rspec/ext/emulab/1";

  # Aliases to commonly used sub-nodes in the manifest:
  mRspec = manifest."{${xmlnsRspec}}rspec";
  mEmulabPortal = mRspec."{${xmlnsEmulab}}portal";
  mNodes = ensureList mRspec."{${xmlnsRspec}}node";
  mNodeHardwareType = node: node."{${xmlnsRspec}}hardware_type";
  mNodeHost = node: node."{${xmlnsRspec}}host";
  mNodeInterfaces = node: ensureList (node."{${xmlnsRspec}}interface");
  mNodeInterfaceIps = interface: ensureList (interface."{${xmlnsRspec}}ip");

  # Generate an "experiment config" struct that is easier to parse
  # than the manifest XML converted to JSON:
  experimentConfig = {
    # Experiment metadata
    "emulabPortal" = mEmulabPortal."@name";
    "emulabProject" = mEmulabPortal."@project";
    "experimentName" = mEmulabPortal."@experiment";

    nodes = lib.listToAttrs (builtins.map (nodeSpec:
      lib.nameValuePair nodeSpec."@client_id" {
        nodeType = (mNodeHardwareType nodeSpec)."@name";
        hostname = builtins.head (lib.splitString "." (mNodeHost nodeSpec)."@name");
        domain = lib.concatStringsSep "." (
          builtins.tail (lib.splitString "." (mNodeHost nodeSpec)."@name"));
        managementIPv4 = (mNodeHost nodeSpec)."@ipv4";

        experimentLinks = lib.listToAttrs (builtins.map (interfaceSpec:
          lib.nameValuePair interfaceSpec."@client_id" {

            # Magic to convert the non-colon-separated MAC address into a
            # colon-separated one:
            macAddress = lib.concatStringsSep ":" (lib.reverseList (
              lib.foldl (acc: char:
                if acc != [] && lib.stringLength (builtins.head acc) == 1 then
                  [ (builtins.head acc + (lib.toLower char)) ] ++ (builtins.tail acc)
                else
                  [ (lib.toLower char) ] ++ acc
              ) [] (lib.filter (char: char != "") (lib.splitString "" interfaceSpec."@mac_address"))
            ));

            ifname = nodeExperimentLink0."${(mNodeHardwareType nodeSpec)."@name"}";

            ipv4 = let
              addrSpec =
                lib.findSingle
                  (addrSpec: addrSpec."@type" == "ipv4")
                  null # Default, if not found
                  (abort "Multiple IPv4 addresses for ${nodeSpec."@client_id"}")
                  (mNodeInterfaceIps interfaceSpec);
            in
              if addrSpec != null then {
                address = addrSpec."@address";
                netmask = addrSpec."@netmask";
                prefixLength = prefixLengthFromIPv4Netmask addrSpec."@netmask";
              } else null;
          }
        ) (mNodeInterfaces nodeSpec));
      }
    ) mNodes);
  };

in
  experimentConfig
