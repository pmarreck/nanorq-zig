{
	description = "nanorq zig tooling";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs systems;
		in {
			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
				in {
					default = pkgs.mkShell {
						packages = with pkgs; [
							zig
							git
							ripgrep
						];
					};
				});

			packages = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
				in {
					nanorq = pkgs.stdenv.mkDerivation {
						pname = "nanorq";
						version = "0.1.0";
						src = self;
						nativeBuildInputs = [ pkgs.zig ];
						dontConfigure = true;
						dontFixup = true;
						buildPhase = ''
							export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
							export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
							mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
							zig build -Doptimize=ReleaseFast --color off
						'';
						installPhase = ''
							mkdir -p $out/bin
							cp -f zig-out/bin/nanorq $out/bin/
							cp -f zig-out/bin/nanorq-bench $out/bin/
						'';
					};
					default = self.packages.${system}.nanorq;
				});

			apps = forAllSystems (system: {
				nanorq = {
					type = "app";
					program = "${self.packages.${system}.nanorq}/bin/nanorq";
				};
				nanorq-bench = {
					type = "app";
					program = "${self.packages.${system}.nanorq}/bin/nanorq-bench";
				};
				default = self.apps.${system}.nanorq;
			});
		};
}
