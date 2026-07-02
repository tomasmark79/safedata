{
  description = "SafeData backup script";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          uchartSrc = pkgs.fetchFromGitHub {
            owner = "Danlino";
            repo = "uchart";
            rev = "e30a79038784ea0d6c795ea85cfb5fc105f7697d";
            hash = "sha256-cDp7lFNjFyQcMrE7luKEtI6zVNgH3UxkOM/Io9H8pZ4=";
          };
        in
        {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "safedata";
            version = "0.1.0";
            src = self;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall

              install -Dm755 safedata.sh "$out/libexec/safedata/safedata.sh"
              install -Dm755 show_stats.sh "$out/libexec/safedata/show_stats.sh"
              cp -R ${uchartSrc} "$out/libexec/safedata/uchart"
              cp -R rules "$out/libexec/safedata/rules"

              makeWrapper "$out/libexec/safedata/safedata.sh" "$out/bin/safedata" \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.findutils
                    pkgs.gawk
                    pkgs.gnused
                    pkgs.gnutar
                    pkgs.gzip
                    pkgs.lvm2
                    pkgs.openssh
                    pkgs.procps
                    pkgs.rsync
                    pkgs.util-linux
                  ]
                }

              makeWrapper "$out/libexec/safedata/show_stats.sh" "$out/bin/safedata-stats" \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.findutils
                    pkgs.gnugrep
                    pkgs.gnused
                    pkgs.python3
                  ]
                }

              runHook postInstall
            '';
          };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/safedata";
        };
        stats = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/safedata-stats";
        };
      });
    };
}
