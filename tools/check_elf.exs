# Load-time facts of vmc.elf, the ones a double-precision engine checks before it runs anything:
#   elixir tools/check_elf.exs [--variant-size=24|40] <vmc.elf>      (default 40: a double engine)
# Exit 1 on any failure. The registered API names are NOT checked here: with sandbox_api they are local
# symbols and the host learns them from the runtime registration, so only an engine run proves them
# (tests/engine/run_vmc.gd). The Lean exports are plain symbols, so they are checked.
defmodule Check do
  @exports ~w(vmc_new vmc_feed_bytes vmc_last_ok vmc_stats_text vmc_time_value vmc_bones_text vmc_roots_text
              vmc_trackers_text vmc_bone_floats vmc_root_floats vmc_tracker_floats vmc_blend_names
              vmc_blend_floats vmc_camera_floats vmc_unknown_text)

  def main(argv) do
    {kv, files, _} = OptionParser.parse(argv, strict: [variant_size: :integer])
    want = kv[:variant_size] || 40
    files == [] && fail("usage: check_elf.exs [--variant-size=N] <elf>")
    Enum.each(files, &check(&1, want))
  end

  defp check(path, want) do
    bin = File.read!(path)
    match?(<<0x7F, "ELF", 2, 1, _::binary>>, bin) || fail("#{path}: not a little-endian ELF64")
    <<_::binary-size(16), type::little-16, machine::little-16, _::binary>> = bin
    type == 2 || fail("#{path}: not ET_EXEC (#{type})")
    machine == 243 || fail("#{path}: not EM_RISCV (#{machine})")
    # The marker is SBXV + u32le; look for it as the section content and require exactly one.
    hits = :binary.matches(bin, "SBXV") |> Enum.map(fn {at, _} -> binary_part(bin, at + 4, 4) end)
    Enum.any?(hits, &(&1 == <<want::little-32>>)) || fail("#{path}: no SBXV marker of size #{want} (found #{inspect(hits)})")
    other = if want == 40, do: 24, else: 40
    Enum.any?(hits, &(&1 == <<other::little-32>>)) && fail("#{path}: also carries a size #{other} marker")
    {out, 0} = System.cmd("llvm-readelf", ["-s", "--wide", path])
    missing = Enum.reject(@exports, &Regex.match?(~r/\sGLOBAL\s+DEFAULT\s+\d+\s#{&1}$/m, out))
    missing == [] || fail("#{path}: missing Lean exports #{inspect(missing)}")
    IO.puts("OK #{path}: ET_EXEC EM_RISCV, SBXV size #{want}, #{length(@exports)} Lean exports")
  end

  defp fail(msg) do
    IO.puts(:stderr, "check_elf: " <> msg)
    System.halt(1)
  end
end

Check.main(System.argv())
