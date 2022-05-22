{ version, src, lib, buildPythonPackage, fetchurl, future, configparser, joinmarketbase, joinmarketdaemon, mnemonic, argon2_cffi, bencoderpyx, pyaes, joinmarketbitcoin, klein, pyjwt, autobahn }:

buildPythonPackage rec {
  pname = "joinmarketclient";
  inherit version src;

  postUnpack = "sourceRoot=$sourceRoot/jmclient";

  checkInputs = [ joinmarketbitcoin joinmarketdaemon ];

  propagatedBuildInputs = [ future configparser joinmarketbase mnemonic argon2_cffi bencoderpyx pyaes klein pyjwt autobahn ];

  patchPhase = ''
    substituteInPlace setup.py \
      --replace "'klein==20.6.0'" "'klein==21.8.0'"
  '';

  meta = with lib; {
    description = "Client library for Bitcoin coinjoins";
    homepage = "https://github.com/Joinmarket-Org/joinmarket-clientserver";
    maintainers = with maintainers; [ nixbitcoin ];
    license = licenses.gpl3;
  };
}
