# vmc.elf: contract-guest-runtime's shared guest build (no ggml) plus the Lean decoder's emitted C.
# Configure with repository-riscv64-sysroot's toolchain.cmake; tools/build.exs does it all.
# The host `lean` must be the release in lean-toolchain (v4.34.1): the emitted C has to match the runtime.
cmake_minimum_required(VERSION 3.16)
project(entities_obstacle_course C CXX)

set(WEFT_ROOT "${CMAKE_SOURCE_DIR}/../.." CACHE PATH "Root of the goal manifest's checkout")
get_filename_component(WEFT_ROOT "${WEFT_ROOT}" ABSOLUTE)
set(GUEST_RUNTIME_ROOT ${WEFT_ROOT}/2-contract/guest-runtime CACHE PATH "contract-guest-runtime's checkout")
# Where the riscv64 Lean core comes from:
#  - LEAN_GUEST_DIR=<interactor-lean-guest checkout>: build it (runtime with runtime-guest.patch, libuv,
#    Init's C). This is what CI does; the first build takes about an hour.
#  - otherwise LEAN_CORE: a ready-made core (libInit.a libStd.a libleanrt.a, gen/include, lean4/src/include)
#    for the same release, by default ~/.cache/lean-guest/v4.34.1. A desk shortcut: that core predates
#    runtime-guest.patch, see LEAN_IO_PATCHED below.
set(LEAN_GUEST_DIR "" CACHE PATH "interactor-lean-guest checkout; builds the Lean core instead of using LEAN_CORE")
set(LEAN_CORE "$ENV{HOME}/.cache/lean-guest/v4.34.1" CACHE PATH "riscv64 Lean core for lean-toolchain's release")
set(LIBUV_A "$ENV{HOME}/.cache/lean-guest/libuv-1.48.0/build-rv64/libuv.a" CACHE FILEPATH "riscv64 libuv")
set(LIBUV_INCLUDE "$ENV{HOME}/.cache/lean-guest/libuv-1.48.0/src/include" CACHE PATH "libuv headers (the runtime's io.cpp includes uv.h)")
set(GUEST_RUNTIME_GGML OFF CACHE BOOL "" FORCE)
if(NOT DEFINED GUEST_ELF_DIR)
	set(GUEST_ELF_DIR ${CMAKE_BINARY_DIR})
endif()
if(NOT LEAN_GUEST_DIR)
	foreach(need ${LEAN_CORE}/lib/libInit.a ${LEAN_CORE}/lib/libStd.a ${LEAN_CORE}/lib/libleanrt.a ${LIBUV_A})
		if(NOT EXISTS ${need})
			message(FATAL_ERROR "missing ${need}")
		endif()
	endforeach()
endif()

include(${GUEST_RUNTIME_ROOT}/cmake/guest_runtime.cmake)
if(LEAN_GUEST_DIR)
	set(LEAN_VERSION "4.34.1" CACHE STRING "must equal lean-toolchain")
	set(LIBUV_VERSION "1.48.0" CACHE STRING "")
	include(${LEAN_GUEST_DIR}/cmake/lean_guest.cmake) # leanrt_guest, leaninit_guest, lean headers
endif()

# The decoder's C, emitted by the host lean. `lake build Vmc.Decode:c` writes .lake/build/ir/Vmc/Decode.c.
find_program(LAKE_EXE lake REQUIRED NO_CMAKE_FIND_ROOT_PATH)
set(DECODE_C ${CMAKE_SOURCE_DIR}/.lake/build/ir/Vmc/Decode.c)
file(GLOB_RECURSE _lean_srcs ${CMAKE_SOURCE_DIR}/Vmc/*.lean)
add_custom_command(OUTPUT ${DECODE_C}
	COMMAND ${LAKE_EXE} build Vmc.Decode:c
	WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
	DEPENDS ${_lean_srcs} ${CMAKE_SOURCE_DIR}/lakefile.lean ${CMAKE_SOURCE_DIR}/lean-toolchain
	VERBATIM)
set_source_files_properties(${DECODE_C} PROPERTIES GENERATED TRUE LANGUAGE C
	COMPILE_OPTIONS "-O2;-ffp-contract=off;-ffunction-sections;-fdata-sections;-w"
	COMPILE_DEFINITIONS "NDEBUG;LEAN_EXPORTING;LEAN_MULTI_THREAD;LEAN_NO_UV;LEAN_NO_OPENSSL")

# The stock runtime opens /dev/urandom, which a sandbox does not have; interactor-lean-guest's
# runtime-guest.patch makes lean_io_get_random_bytes call getrandom. A core built before that patch
# needs the patched io.cpp compiled in ahead of libleanrt.a (the linker takes the first definition).
set(LEAN_IO_PATCHED "" CACHE FILEPATH "io.cpp with runtime-guest.patch applied, for a core built without it")
set(_extra)
if(LEAN_IO_PATCHED)
	set(_extra ${LEAN_IO_PATCHED})
	set_source_files_properties(${LEAN_IO_PATCHED} PROPERTIES COMPILE_DEFINITIONS "NDEBUG;LEAN_EXPORTING;LEAN_MULTI_THREAD;LEAN_NO_UV;LEAN_NO_OPENSSL")
endif()
add_stage_elf(vmc ${CMAKE_SOURCE_DIR}/guest/vmc/main.cpp ${DECODE_C} ${_extra})
target_compile_features(vmc PRIVATE cxx_std_20)
target_compile_options(vmc PRIVATE -ffp-contract=off -ffunction-sections -fdata-sections)
target_compile_definitions(vmc PRIVATE LEAN_MULTI_THREAD LEAN_NO_UV LEAN_NO_OPENSSL)
if(LEAN_GUEST_DIR)
	# leaninit_guest links leanrt_guest and exports the include paths.
	target_link_libraries(vmc PRIVATE -Wl,--gc-sections leaninit_guest pthread)
else()
	target_include_directories(vmc PRIVATE ${LEAN_CORE}/gen/include ${LEAN_CORE}/lean4/src/include ${LEAN_CORE}/lean4/src ${LIBUV_INCLUDE})
	# add_sandbox_program adds no --gc-sections, and the Lean core is large without it.
	target_link_libraries(vmc PRIVATE -Wl,--gc-sections -Wl,--start-group ${LEAN_CORE}/lib/libInit.a
		${LEAN_CORE}/lib/libStd.a ${LEAN_CORE}/lib/libleanrt.a ${LIBUV_A} -Wl,--end-group pthread)
endif()
