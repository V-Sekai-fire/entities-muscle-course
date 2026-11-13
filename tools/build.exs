# Builds vmc.elf from this checkout and the goal manifest's sibling checkouts (2-contract/guest-runtime,
# 5-repository/riscv64-sysroot), the way interactor-motion-matching-guest's tools/build.exs builds mm.elf.
#   elixir tools/build.exs [--sysroot=<repository-riscv64-sysroot>] [--build=<dir>]
# WEFT_ROOT is the manifest checkout; it defaults to two levels above this repo (4-entities/obstacle-course).
defmodule Build do
  @root Path.expand("..", __DIR__)

  def main(argv) do
    {kv, _, _} = OptionParser.parse(argv, strict: [sysroot: :string, build: :string])
    weft = Path.expand(System.get_env("WEFT_ROOT") || Path.join(@root, "../.."))
    for t <- ~w(cmake ninja clang++ ld.lld), do: System.find_executable(t) || fail("#{t} is not on PATH")
    sysroot = Path.expand(kv[:sysroot] || System.get_env("RISCV64_SYSROOT") || Path.join(weft, "5-repository/riscv64-sysroot"))
    toolchain = Path.join(sysroot, "toolchain.cmake")
    File.exists?(toolchain) || fail("no toolchain.cmake under #{sysroot}")
    File.dir?(Path.join(weft, "2-contract/guest-runtime")) || fail("no 2-contract/guest-runtime under #{weft}")
    build = Path.expand(kv[:build] || Path.join(@root, "build/rv64"))
    File.mkdir_p!(build)

    unless File.exists?(Path.join(build, "build.ninja")) do
      run("cmake", ["-S", @root, "-B", build, "-G", "Ninja", "-DCMAKE_TOOLCHAIN_FILE=#{toolchain}", "-DWEFT_ROOT=#{weft}"] ++ extra_args())
    end

    run("cmake", ["--build", build, "--target", "vmc"])
    elf = File.read!(Path.join(build, "vmc.elf"))
    IO.puts("== vmc.elf: #{byte_size(elf)} bytes, sha256 #{Base.encode16(:crypto.hash(:sha256, elf), case: :lower)}")
  end

  # Extra cmake flags, e.g. VMC_CMAKE_ARGS="-DLEAN_CORE=/path -DLEAN_IO_PATCHED=/path/io.cpp".
  defp extra_args, do: String.split(System.get_env("VMC_CMAKE_ARGS") || "", " ", trim: true)

  defp run(cmd, args) do
    {_, code} = System.cmd(cmd, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true)
    code == 0 || fail("#{cmd} exited #{code}")
  end

  defp fail(msg) do
    IO.puts(:stderr, "build: " <> msg)
    System.halt(1)
  end
end

Build.main(System.argv())
