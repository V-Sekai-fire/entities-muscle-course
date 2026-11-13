import Lake
open Lake DSL

-- The library is not named after its module: `lake build Vmc.Decode:c` fails with
-- "unknown lean_lib facet c" when a lean_lib and a module share a name.
package vmc

lean_lib VmcLib where
  roots := #[`Vmc.Decode]

lean_exe vmc_witness where
  root := `VmcWitness
