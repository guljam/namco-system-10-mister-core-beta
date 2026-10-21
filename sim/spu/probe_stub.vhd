-- Sim stand-in for rtl/ns10/ns10_probe.sv: the probe value goes to a package signal the testbench reads.
library IEEE;
use IEEE.std_logic_1164.all;

package tb_probe_pkg is
   signal probe_sig   : std_logic_vector(63 downto 0);
   signal probe2_sig  : std_logic_vector(63 downto 0);
   signal probe_clear : std_logic := '0';
end package;

library IEEE;
use IEEE.std_logic_1164.all;
use work.tb_probe_pkg.all;

entity ns10_probe is
   generic (ID : string := "PRB0");
   port (probe : in std_logic_vector(63 downto 0); source : out std_logic_vector(0 downto 0));
end entity;

architecture sim of ns10_probe is
begin
   g1 : if ID = "SPUT" generate probe_sig  <= probe; end generate;
   g2 : if ID = "SPU2" generate probe2_sig <= probe; end generate;
   source(0) <= probe_clear;
end architecture;
