# vmc.elf on its own: contract-guest-runtime's shared guest build (no ggml), like mm.elf.
# Configure with repository-riscv64-sysroot's toolchain.cmake; tools/build.exs does it all.
cmake_minimum_required(VERSION 3.16)
project(entities_obstacle_course C CXX)

set(WEFT_ROOT "${CMAKE_SOURCE_DIR}/../.." CACHE PATH "Root of the goal manifest's checkout")
get_filename_component(WEFT_ROOT "${WEFT_ROOT}" ABSOLUTE)
set(GUEST_RUNTIME_ROOT ${WEFT_ROOT}/2-contract/guest-runtime CACHE PATH "contract-guest-runtime's checkout")
set(GUEST_RUNTIME_GGML OFF CACHE BOOL "" FORCE)
if(NOT DEFINED GUEST_ELF_DIR)
	set(GUEST_ELF_DIR ${CMAKE_BINARY_DIR})
endif()

include(${GUEST_RUNTIME_ROOT}/cmake/guest_runtime.cmake)

add_stage_elf(vmc ${CMAKE_SOURCE_DIR}/guest/vmc/main.cpp)
target_include_directories(vmc PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_features(vmc PRIVATE cxx_std_20)
target_compile_options(vmc PRIVATE -ffp-contract=off)
