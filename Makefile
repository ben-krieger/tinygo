
# aliases
all: tinygo

# Default build and source directories, as created by `make llvm-build`.
LLVM_BUILDDIR ?= llvm-build
LLVM_PROJECTDIR ?= llvm-project
CLANG_SRC ?= $(LLVM_PROJECTDIR)/clang
LLD_SRC ?= $(LLVM_PROJECTDIR)/lld

# Try to autodetect LLVM build tools.
detect = $(shell command -v $(1) 2> /dev/null && echo $(1))
CLANG ?= $(word 1,$(abspath $(call detect,llvm-build/bin/clang))$(call detect,clang-11)$(call detect,clang-10)$(call detect,clang))
LLVM_AR ?= $(word 1,$(abspath $(call detect,llvm-build/bin/llvm-ar))$(call detect,llvm-ar-11)$(call detect,llvm-ar-10)$(call detect,llvm-ar))
LLVM_NM ?= $(word 1,$(abspath $(call detect,llvm-build/bin/llvm-nm))$(call detect,llvm-nm-11)$(call detect,llvm-nm-10)$(call detect,llvm-nm))

# Go binary and GOROOT to select
GO ?= go
export GOROOT = $(shell $(GO) env GOROOT)

# md5sum binary
MD5SUM = md5sum

# tinygo binary for tests
TINYGO ?= $(word 1,$(call detect,tinygo)$(call detect,build/tinygo))

# Use CCACHE for LLVM if possible
ifneq (, $(shell command -v ccache 2> /dev/null))
    LLVM_OPTION += '-DLLVM_CCACHE_BUILD=ON'
endif

# Allow enabling LLVM assertions
ifeq (1, $(ASSERT))
    LLVM_OPTION += '-DLLVM_ENABLE_ASSERTIONS=ON'
else
    LLVM_OPTION += '-DLLVM_ENABLE_ASSERTIONS=OFF'
endif

.PHONY: all tinygo test $(LLVM_BUILDDIR) llvm-source clean fmt gen-device gen-device-nrf gen-device-nxp gen-device-avr

LLVM_COMPONENTS = all-targets analysis asmparser asmprinter bitreader bitwriter codegen core coroutines coverage debuginfodwarf executionengine frontendopenmp instrumentation interpreter ipo irreader linker lto mc mcjit objcarcopts option profiledata scalaropts support target

ifeq ($(OS),Windows_NT)
    EXE = .exe
    START_GROUP = -Wl,--start-group
    END_GROUP = -Wl,--end-group

    # LLVM compiled using MinGW on Windows appears to have problems with threads.
    # Without this flag, linking results in errors like these:
    #     libLLVMSupport.a(Threading.cpp.obj):Threading.cpp:(.text+0x55): undefined reference to `std::thread::hardware_concurrency()'
    LLVM_OPTION += -DLLVM_ENABLE_THREADS=OFF -DLLVM_ENABLE_PIC=OFF

    CGO_CPPFLAGS += -DCINDEX_NO_EXPORTS
    CGO_LDFLAGS += -static -static-libgcc -static-libstdc++
    CGO_LDFLAGS_EXTRA += -lversion

    LIBCLANG_NAME = libclang

else ifeq ($(shell uname -s),Darwin)
    MD5SUM = md5
    LIBCLANG_NAME = clang
else ifeq ($(shell uname -s),FreeBSD)
    MD5SUM = md5
    LIBCLANG_NAME = clang
    START_GROUP = -Wl,--start-group
    END_GROUP = -Wl,--end-group
else
    LIBCLANG_NAME = clang
    START_GROUP = -Wl,--start-group
    END_GROUP = -Wl,--end-group
endif

# Libraries that should be linked in for the statically linked Clang.
CLANG_LIB_NAMES = clangAnalysis clangARCMigrate clangAST clangASTMatchers clangBasic clangCodeGen clangCrossTU clangDriver clangDynamicASTMatchers clangEdit clangFormat clangFrontend clangFrontendTool clangHandleCXX clangHandleLLVM clangIndex clangLex clangParse clangRewrite clangRewriteFrontend clangSema clangSerialization clangStaticAnalyzerCheckers clangStaticAnalyzerCore clangStaticAnalyzerFrontend clangTooling clangToolingASTDiff clangToolingCore clangToolingInclusions
CLANG_LIBS = $(START_GROUP) $(addprefix -l,$(CLANG_LIB_NAMES)) $(END_GROUP) -lstdc++

# Libraries that should be linked in for the statically linked LLD.
LLD_LIB_NAMES = lldCOFF lldCommon lldCore lldDriver lldELF lldMachO lldMinGW lldReaderWriter lldWasm lldYAML
LLD_LIBS = $(START_GROUP) $(addprefix -l,$(LLD_LIB_NAMES)) $(END_GROUP)

# Other libraries that are needed to link TinyGo.
EXTRA_LIB_NAMES = LLVMInterpreter

# These build targets appear to be the only ones necessary to build all TinyGo
# dependencies. Only building a subset significantly speeds up rebuilding LLVM.
# The Makefile rules convert a name like lldELF to lib/liblldELF.a to match the
# library path (for ninja).
# This list also includes a few tools that are necessary as part of the full
# TinyGo build.
NINJA_BUILD_TARGETS = clang llvm-config llvm-ar llvm-nm $(addprefix lib/lib,$(addsuffix .a,$(LIBCLANG_NAME) $(CLANG_LIB_NAMES) $(LLD_LIB_NAMES) $(EXTRA_LIB_NAMES)))

# For static linking.
ifneq ("$(wildcard $(LLVM_BUILDDIR)/bin/llvm-config*)","")
    CGO_CPPFLAGS+=$(shell $(LLVM_BUILDDIR)/bin/llvm-config --cppflags) -I$(abspath $(LLVM_BUILDDIR))/tools/clang/include -I$(abspath $(CLANG_SRC))/include -I$(abspath $(LLD_SRC))/include
    CGO_CXXFLAGS=-std=c++14
    CGO_LDFLAGS+=$(abspath $(LLVM_BUILDDIR))/lib/lib$(LIBCLANG_NAME).a -L$(abspath $(LLVM_BUILDDIR)/lib) $(CLANG_LIBS) $(LLD_LIBS) $(shell $(LLVM_BUILDDIR)/bin/llvm-config --ldflags --libs --system-libs $(LLVM_COMPONENTS)) -lstdc++ $(CGO_LDFLAGS_EXTRA)
endif


clean:
	@rm -rf build

FMT_PATHS = ./*.go builder cgo compiler interp loader src/device/arm src/examples src/machine src/os src/reflect src/runtime src/sync src/syscall src/internal/reflectlite transform
fmt:
	@gofmt -l -w $(FMT_PATHS)
fmt-check:
	@unformatted=$$(gofmt -l $(FMT_PATHS)); [ -z "$$unformatted" ] && exit 0; echo "Unformatted:"; for fn in $$unformatted; do echo "  $$fn"; done; exit 1


gen-device: gen-device-avr gen-device-esp gen-device-nrf gen-device-sam gen-device-sifive gen-device-kendryte gen-device-nxp
ifneq ($(STM32), 0)
gen-device: gen-device-stm32
endif

gen-device-avr:
	@if [ ! -e lib/avr/README.md ]; then echo "Submodules have not been downloaded. Please download them using:\n  git submodule update --init"; exit 1; fi
	$(GO) build -o ./build/gen-device-avr ./tools/gen-device-avr/
	./build/gen-device-avr lib/avr/packs/atmega src/device/avr/
	./build/gen-device-avr lib/avr/packs/tiny src/device/avr/
	@GO111MODULE=off $(GO) fmt ./src/device/avr

build/gen-device-svd: ./tools/gen-device-svd/*.go
	$(GO) build -o $@ ./tools/gen-device-svd/

gen-device-esp: build/gen-device-svd
	./build/gen-device-svd -source=https://github.com/posborne/cmsis-svd/tree/master/data/Espressif-Community -interrupts=software lib/cmsis-svd/data/Espressif-Community/ src/device/esp/
	GO111MODULE=off $(GO) fmt ./src/device/esp

gen-device-nrf: build/gen-device-svd
	./build/gen-device-svd -source=https://github.com/NordicSemiconductor/nrfx/tree/master/mdk lib/nrfx/mdk/ src/device/nrf/
	GO111MODULE=off $(GO) fmt ./src/device/nrf

gen-device-nxp: build/gen-device-svd
	./build/gen-device-svd -source=https://github.com/posborne/cmsis-svd/tree/master/data/NXP lib/cmsis-svd/data/NXP/ src/device/nxp/
	GO111MODULE=off $(GO) fmt ./src/device/nxp

gen-device-sam: build/gen-device-svd
	./build/gen-device-svd -source=https://github.com/posborne/cmsis-svd/tree/master/data/Atmel lib/cmsis-svd/data/Atmel/ src/device/sam/
	GO111MODULE=off $(GO) fmt ./src/device/sam

gen-device-sifive: build/gen-device-svd
	./build/gen-device-svd -source=https://github.com/posborne/cmsis-svd/tree/master/data/SiFive-Community -interrupts=software lib/cmsis-svd/data/SiFive-Community/ src/device/sifive/
	GO111MODULE=off $(GO) fmt ./src/device/sifive

gen-device-kendryte: build/gen-device-svd
	./build/gen-device-svd -source=https://github.com/posborne/cmsis-svd/tree/master/data/Kendryte-Community -interrupts=software lib/cmsis-svd/data/Kendryte-Community/ src/device/kendryte/
	GO111MODULE=off $(GO) fmt ./src/device/kendryte

gen-device-stm32: build/gen-device-svd
	./build/gen-device-svd -source=https://github.com/tinygo-org/stm32-svd lib/stm32-svd/svd src/device/stm32/
	GO111MODULE=off $(GO) fmt ./src/device/stm32


# Get LLVM sources.
$(LLVM_PROJECTDIR)/README.md:
	git clone -b xtensa_release_11.0.0 --depth=1 https://github.com/tinygo-org/llvm-project $(LLVM_PROJECTDIR)
llvm-source: $(LLVM_PROJECTDIR)/README.md

# Configure LLVM.
TINYGO_SOURCE_DIR=$(shell pwd)
$(LLVM_BUILDDIR)/build.ninja: llvm-source
	mkdir -p $(LLVM_BUILDDIR); cd $(LLVM_BUILDDIR); cmake -G Ninja $(TINYGO_SOURCE_DIR)/$(LLVM_PROJECTDIR)/llvm "-DLLVM_TARGETS_TO_BUILD=X86;ARM;AArch64;RISCV;WebAssembly" "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=AVR;Xtensa" -DCMAKE_BUILD_TYPE=Release -DLIBCLANG_BUILD_STATIC=ON -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_Z3_SOLVER=OFF -DLLVM_ENABLE_OCAMLDOC=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_TOOL_CLANG_TOOLS_EXTRA_BUILD=OFF $(LLVM_OPTION)

# Build LLVM.
$(LLVM_BUILDDIR): $(LLVM_BUILDDIR)/build.ninja
	cd $(LLVM_BUILDDIR); ninja $(NINJA_BUILD_TARGETS)


# Build wasi-libc sysroot
.PHONY: wasi-libc
wasi-libc: lib/wasi-libc/sysroot/lib/wasm32-wasi/libc.a
lib/wasi-libc/sysroot/lib/wasm32-wasi/libc.a:
	@if [ ! -e lib/wasi-libc/Makefile ]; then echo "Submodules have not been downloaded. Please download them using:\n  git submodule update --init"; exit 1; fi
	cd lib/wasi-libc && make -j4 WASM_CC=$(CLANG) WASM_AR=$(LLVM_AR) WASM_NM=$(LLVM_NM)


# Build the Go compiler.
tinygo:
	@if [ ! -f "$(LLVM_BUILDDIR)/bin/llvm-config" ]; then echo "Fetch and build LLVM first by running:"; echo "  make llvm-source"; echo "  make $(LLVM_BUILDDIR)"; exit 1; fi
	CGO_CPPFLAGS="$(CGO_CPPFLAGS)" CGO_CXXFLAGS="$(CGO_CXXFLAGS)" CGO_LDFLAGS="$(CGO_LDFLAGS)" $(GO) build -buildmode exe -o build/tinygo$(EXE) -tags byollvm -ldflags="-X main.gitSha1=`git rev-parse --short HEAD`" .

test: wasi-libc
	CGO_CPPFLAGS="$(CGO_CPPFLAGS)" CGO_CXXFLAGS="$(CGO_CXXFLAGS)" CGO_LDFLAGS="$(CGO_LDFLAGS)" $(GO) test -v -buildmode exe -tags byollvm ./builder ./cgo ./compileopts ./compiler ./interp ./transform .

# Test known-working standard library packages.
# TODO: do this in one command, parallelize, and only show failing tests (no
# implied -v flag).
.PHONY: tinygo-test
tinygo-test:
	$(TINYGO) test container/heap
	$(TINYGO) test container/list
	$(TINYGO) test container/ring
	$(TINYGO) test crypto/des
	$(TINYGO) test encoding/ascii85
	$(TINYGO) test encoding/base32
	$(TINYGO) test encoding/hex
	$(TINYGO) test hash/adler32
	$(TINYGO) test hash/fnv
	$(TINYGO) test hash/crc64
	$(TINYGO) test math
	$(TINYGO) test math/cmplx
	$(TINYGO) test text/scanner
	$(TINYGO) test unicode/utf8

.PHONY: smoketest
smoketest:
	$(TINYGO) version
	# test all examples (except pwm)
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/adc
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/blinkm
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/blinky2
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/button
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/button2
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/echo
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=circuitplay-express examples/i2s
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/mcp3008
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=microbit            examples/microbit-blink
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/pininterrupt
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/serial
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/systick
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040            examples/test
	@$(MD5SUM) test.hex
	# test simulated boards on play.tinygo.org
	$(TINYGO) build             -o test.wasm -tags=arduino              examples/blinky1
	@$(MD5SUM) test.wasm
	$(TINYGO) build             -o test.wasm -tags=hifive1b             examples/blinky1
	@$(MD5SUM) test.wasm
	$(TINYGO) build             -o test.wasm -tags=reelboard            examples/blinky1
	@$(MD5SUM) test.wasm
	$(TINYGO) build             -o test.wasm -tags=pca10040             examples/blinky2
	@$(MD5SUM) test.wasm
	$(TINYGO) build             -o test.wasm -tags=pca10056             examples/blinky2
	@$(MD5SUM) test.wasm
	$(TINYGO) build             -o test.wasm -tags=circuitplay_express  examples/blinky1
	@$(MD5SUM) test.wasm
	# test all targets/boards
	$(TINYGO) build -size short -o test.hex -target=pca10040-s132v6     examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=microbit            examples/echo
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=microbit-s110v8     examples/echo
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=microbit-v2         examples/microbit-blink
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=microbit-v2-s113v7  examples/microbit-blink
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=nrf52840-mdk        examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10031            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=reelboard           examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=reelboard           examples/blinky2
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10056            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10056            examples/blinky2
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10059            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10059            examples/blinky2
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=itsybitsy-m0        examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=feather-m0          examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=trinket-m0          examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=circuitplay-express examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=circuitplay-bluefruit examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=circuitplay-express examples/i2s
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=clue-alpha          examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.gba -target=gameboy-advance     examples/gba-display
	@$(MD5SUM) test.gba
	$(TINYGO) build -size short -o test.hex -target=itsybitsy-m4        examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=feather-m4          examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pybadge             examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=metro-m4-airlift    examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pyportal            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=particle-argon      examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=particle-boron      examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=particle-xenon      examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pinetime-devkit0    examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=x9pro               examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10056-s140v7     examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=reelboard-s140v7    examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=wioterminal         examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pygamer             examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=xiao                examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=circuitplay-express examples/dac
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pyportal            examples/dac
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=feather-nrf52840  	examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=itsybitsy-nrf52840  examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=qtpy  				examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=teensy40            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=teensy36            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=p1am-100            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=atsame54-xpro       examples/blinky1
	@$(MD5SUM) test.hex
	# test pwm
	$(TINYGO) build -size short -o test.hex -target=itsybitsy-m0        examples/pwm
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=itsybitsy-m4        examples/pwm
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=feather-m4          examples/pwm
	@$(MD5SUM) test.hex
ifneq ($(STM32), 0)
	$(TINYGO) build -size short -o test.hex -target=bluepill            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=feather-stm32f405   examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=lgt92               examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=nucleo-f103rb       examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=nucleo-f722ze       examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=nucleo-l031k6       examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=nucleo-l432kc       examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=nucleo-l552ze       examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=stm32f4disco        examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=stm32f4disco        examples/blinky2
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=stm32f4disco-1      examples/blinky1
	@$(MD5SUM) test.hex
endif
ifneq ($(AVR), 0)
	$(TINYGO) build -size short -o test.hex -target=atmega1284p         examples/serial
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=arduino             examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=arduino             examples/pwm
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=arduino -scheduler=tasks  examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=arduino-mega1280    examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=arduino-mega1280    examples/pwm
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=arduino-nano        examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=digispark           examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=digispark -gc=leaking examples/blinky1
	@$(MD5SUM) test.hex
endif
ifneq ($(XTENSA), 0)
	$(TINYGO) build -size short -o test.bin -target=esp32-mini32      	examples/blinky1
	@$(MD5SUM) test.bin
	$(TINYGO) build -size short -o test.bin -target=nodemcu             examples/blinky1
	@$(MD5SUM) test.bin
endif
	$(TINYGO) build -size short -o test.hex -target=hifive1b            examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=hifive1-qemu        examples/serial
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=maixbit             examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build             -o wasm.wasm -target=wasm               examples/wasm/export
	$(TINYGO) build             -o wasm.wasm -target=wasm               examples/wasm/main
	# test various compiler flags
	$(TINYGO) build -size short -o test.hex -target=pca10040 -gc=none -scheduler=none examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build -size short -o test.hex -target=pca10040 -opt=1     examples/blinky1
	@$(MD5SUM) test.hex
	$(TINYGO) build             -o test.nro -target=nintendoswitch      examples/serial
	@$(MD5SUM) test.nro
	$(TINYGO) build -size short -o test.hex -target=pca10040 -opt=0     ./testdata/stdlib.go
	@$(MD5SUM) test.hex


wasmtest:
	$(GO) test ./tests/wasm

build/release: tinygo gen-device wasi-libc
	@mkdir -p build/release/tinygo/bin
	@mkdir -p build/release/tinygo/lib/clang/include
	@mkdir -p build/release/tinygo/lib/CMSIS/CMSIS
	@mkdir -p build/release/tinygo/lib/compiler-rt/lib
	@mkdir -p build/release/tinygo/lib/nrfx
	@mkdir -p build/release/tinygo/lib/picolibc/newlib/libc
	@mkdir -p build/release/tinygo/lib/wasi-libc
	@mkdir -p build/release/tinygo/pkg/armv6m-none-eabi
	@mkdir -p build/release/tinygo/pkg/armv7m-none-eabi
	@mkdir -p build/release/tinygo/pkg/armv7em-none-eabi
	@echo copying source files
	@cp -p  build/tinygo$(EXE)           build/release/tinygo/bin
	@cp -p $(abspath $(CLANG_SRC))/lib/Headers/*.h build/release/tinygo/lib/clang/include
	@cp -rp lib/CMSIS/CMSIS/Include      build/release/tinygo/lib/CMSIS/CMSIS
	@cp -rp lib/CMSIS/README.md          build/release/tinygo/lib/CMSIS
	@cp -rp lib/compiler-rt/lib/builtins build/release/tinygo/lib/compiler-rt/lib
	@cp -rp lib/compiler-rt/LICENSE.TXT  build/release/tinygo/lib/compiler-rt
	@cp -rp lib/compiler-rt/README.txt   build/release/tinygo/lib/compiler-rt
	@cp -rp lib/nrfx/*                   build/release/tinygo/lib/nrfx
	@cp -rp lib/picolibc/newlib/libc/ctype       build/release/tinygo/lib/picolibc/newlib/libc
	@cp -rp lib/picolibc/newlib/libc/include     build/release/tinygo/lib/picolibc/newlib/libc
	@cp -rp lib/picolibc/newlib/libc/locale      build/release/tinygo/lib/picolibc/newlib/libc
	@cp -rp lib/picolibc/newlib/libc/string      build/release/tinygo/lib/picolibc/newlib/libc
	@cp -rp lib/picolibc/newlib/libc/tinystdio   build/release/tinygo/lib/picolibc/newlib/libc
	@cp -rp lib/picolibc-include         build/release/tinygo/lib
	@cp -rp lib/wasi-libc/sysroot        build/release/tinygo/lib/wasi-libc/sysroot
	@cp -rp src                          build/release/tinygo/src
	@cp -rp targets                      build/release/tinygo/targets
	./build/tinygo build-library -target=armv6m-none-eabi  -o build/release/tinygo/pkg/armv6m-none-eabi/compiler-rt.a compiler-rt
	./build/tinygo build-library -target=armv7m-none-eabi  -o build/release/tinygo/pkg/armv7m-none-eabi/compiler-rt.a compiler-rt
	./build/tinygo build-library -target=armv7em-none-eabi -o build/release/tinygo/pkg/armv7em-none-eabi/compiler-rt.a compiler-rt
	./build/tinygo build-library -target=armv6m-none-eabi  -o build/release/tinygo/pkg/armv6m-none-eabi/picolibc.a picolibc
	./build/tinygo build-library -target=armv7m-none-eabi  -o build/release/tinygo/pkg/armv7m-none-eabi/picolibc.a picolibc
	./build/tinygo build-library -target=armv7em-none-eabi -o build/release/tinygo/pkg/armv7em-none-eabi/picolibc.a picolibc

release: build/release
	tar -czf build/release.tar.gz -C build/release tinygo

deb: build/release
	@mkdir -p build/release-deb/usr/local/bin
	@mkdir -p build/release-deb/usr/local/lib
	cp -ar build/release/tinygo build/release-deb/usr/local/lib/tinygo
	ln -sf ../lib/tinygo/bin/tinygo build/release-deb/usr/local/bin/tinygo
	fpm -f -s dir -t deb -n tinygo -v $(shell grep "const Version = " goenv/version.go | awk '{print $$NF}') -m '@tinygo-org' --description='TinyGo is a Go compiler for small places.' --license='BSD 3-Clause' --url=https://tinygo.org/ --deb-changelog CHANGELOG.md -p build/release.deb -C ./build/release-deb
