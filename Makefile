# Diretta UPnP Renderer - Makefile with SDK Version Auto-Detection
# FIXED VERSION - Simplified SDK detection
# Supports: x64 (v2/v3/v4/zen4), aarch64, riscv64
# 
# Usage:
#   make                              # Auto-detect
#   make ARCH_NAME=x64-linux-15v3     # Manual override
#   make ARCH_NAME=aarch64-linux-15   # Raspberry Pi
#   make NOLOG=1                      # Use -nolog variant

# ============================================
# Compiler Settings
# ============================================

CXX = g++
CXXFLAGS = -std=c++17 -Wall -Wextra -O2 -pthread
LDFLAGS = -pthread

# ============================================
# Manual Override Option / Architecture detection
# ============================================

UNAME_M := $(shell uname -m)

# Detect base architecture (for auto mode)
ifeq ($(UNAME_M),x86_64)
    BASE_ARCH = x64
    ARCH_DESC_BASE = x86_64 (Intel/AMD 64-bit)
else ifeq ($(UNAME_M),aarch64)
    BASE_ARCH = aarch64
    ARCH_DESC_BASE = ARM64 (aarch64)
else ifeq ($(UNAME_M),arm64)
    BASE_ARCH = aarch64
    ARCH_DESC_BASE = ARM64 (arm64 → aarch64)
else ifeq ($(UNAME_M),armv7l)
    BASE_ARCH = arm
    ARCH_DESC_BASE = ARM 32-bit (armv7l)
    $(warning ARM 32-bit detected but not officially supported by Diretta SDK)
else ifeq ($(UNAME_M),riscv64)
    BASE_ARCH = riscv64
    ARCH_DESC_BASE = RISC-V 64-bit
else
    BASE_ARCH = unknown
    ARCH_DESC_BASE = Unknown: $(UNAME_M)
endif

# ============================================
# Architecture-Specific Variant Detection (auto mode)
# ============================================

# DEFAULT_VARIANT is only used when ARCH_NAME/VARIANT are not given
ifeq ($(BASE_ARCH),x64)
    # x64: Auto-detect CPU capabilities
    HAS_AVX2   := $(shell grep -q avx2 /proc/cpuinfo 2>/dev/null && echo 1 || echo 0)
    HAS_AVX512 := $(shell grep -q avx512 /proc/cpuinfo 2>/dev/null && echo 1 || echo 0)
    IS_ZEN4    := $(shell lscpu 2>/dev/null | grep -qi "AMD.*Zen 4" && echo 1 || echo 0)
    
    ifeq ($(IS_ZEN4),1)
        DEFAULT_VARIANT = x64-linux-15zen4
        CPU_DESC = AMD Zen 4 detected
    else ifeq ($(HAS_AVX512),1)
        DEFAULT_VARIANT = x64-linux-15v4
        CPU_DESC = AVX512 detected (x86-64-v4)
    else ifeq ($(HAS_AVX2),1)
        DEFAULT_VARIANT = x64-linux-15v3
        CPU_DESC = AVX2 detected (x86-64-v3)
    else
        DEFAULT_VARIANT = x64-linux-15v2
        CPU_DESC = Basic x64 (x86-64-v2)
    endif

else ifeq ($(BASE_ARCH),aarch64)
    # aarch64: Detect based on page size and device model
    # RPi5 uses 16KB pages (k16 variant), RPi3/4 use 4KB pages (standard variant)
    PAGE_SIZE := $(shell getconf PAGESIZE 2>/dev/null || echo 4096)
    
    # Also check device-tree model for explicit RPi5 detection
    IS_RPI5 := $(shell [ -r /proc/device-tree/model ] && grep -q "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null && echo 1 || echo 0)
    
    # Use k16 variant ONLY if:
    # - Explicitly detected as Raspberry Pi 5, OR
    # - Page size is 16384 (16KB)
    ifeq ($(IS_RPI5),1)
        DEFAULT_VARIANT = aarch64-linux-15k16
        CPU_DESC = Raspberry Pi 5 detected (16KB pages, k16 variant)
    else ifeq ($(PAGE_SIZE),16384)
        DEFAULT_VARIANT = aarch64-linux-15k16
        CPU_DESC = 16KB page size detected (k16 variant)
    else
        DEFAULT_VARIANT = aarch64-linux-15
        CPU_DESC = $(PAGE_SIZE)-byte pages (standard variant)
    endif

else ifeq ($(BASE_ARCH),riscv64)
    DEFAULT_VARIANT = riscv64-linux-15
    CPU_DESC = RISC-V 64-bit

else
    DEFAULT_VARIANT = unknown
    CPU_DESC = Unknown architecture
endif

# ============================================
# Variant resolution (ARCH_NAME / VARIANT / auto)
# ============================================

# 1. Full manual override: ARCH_NAME=x64-linux-15v3
ifdef ARCH_NAME
    FULL_VARIANT = $(ARCH_NAME)
else
    # 2. Only VARIANT given: VARIANT=15v4 → x64-linux-15v4
    ifdef VARIANT
        FULL_VARIANT = $(BASE_ARCH)-linux-$(VARIANT)
    else
        # 3. Pure auto-detect
        FULL_VARIANT = $(DEFAULT_VARIANT)
    endif
endif

# Derived values from FULL_VARIANT
DIRETTA_ARCH      = $(word 1,$(subst -, ,$(FULL_VARIANT)))
DIRETTA_LIB_SUFFIX = $(subst $(DIRETTA_ARCH)-linux-,,$(FULL_VARIANT))

ARCH_DESC = $(ARCH_DESC_BASE) - $(CPU_DESC)

# ============================================
# Add -nolog suffix if requested
# ============================================

ifdef NOLOG
    NOLOG_SUFFIX = -nolog
else
    NOLOG_SUFFIX = 
endif

# ============================================
# Construct Library Names
# ============================================

DIRETTA_LIB_NAME = libDirettaHost_$(FULL_VARIANT)$(NOLOG_SUFFIX).a
ACQUA_LIB_NAME   = libACQUA_$(FULL_VARIANT)$(NOLOG_SUFFIX).a

$(info )
$(info ═══════════════════════════════════════════════════════)
$(info   Diretta UPnP Renderer - Build Configuration)
$(info ═══════════════════════════════════════════════════════)
$(info Architecture:  $(ARCH_DESC))
$(info Variant:       $(FULL_VARIANT))
$(info Library:       $(DIRETTA_LIB_NAME))
$(info ═══════════════════════════════════════════════════════)
$(info )

# ============================================
# Diretta SDK Auto-Detection - SIMPLIFIED VERSION
# ============================================

ifdef DIRETTA_SDK_PATH
    SDK_PATH = $(DIRETTA_SDK_PATH)
    SDK_VERSION = custom
    $(info ✓ Using SDK from environment: $(SDK_PATH))
else
    # Search for DirettaHostSDK_* in common locations
    SDK_CANDIDATES := $(shell find $(HOME) . .. /opt $(HOME)/audio /usr/local \
        -maxdepth 1 -type d -name 'DirettaHostSDK_*' 2>/dev/null | sort -V | tail -1)
    
    ifneq ($(SDK_CANDIDATES),)
        SDK_PATH = $(SDK_CANDIDATES)
        SDK_VERSION = $(subst DirettaHostSDK_,,$(notdir $(SDK_PATH)))
        $(info ✓ SDK auto-detected: $(SDK_PATH))
        $(info ✓ SDK version: $(SDK_VERSION))
    else
        $(info )
        $(info ❌ Diretta SDK not found!)
        $(info )
        $(info 📁 Searched for DirettaHostSDK_* in:)
        $(info    $(HOME)/)
        $(info    ./)
        $(info    ../)
        $(info    /opt/)
        $(info    $(HOME)/audio/)
        $(info    /usr/local/)
        $(info )
        $(info 💡 Solutions:)
        $(info    1. Download SDK to one of the locations above)
        $(info    2. Or set: make DIRETTA_SDK_PATH=/your/path/DirettaHostSDK_XXX)
        $(info )
        $(error SDK not found)
    endif
endif

# ============================================
# Verify SDK Installation
# ============================================

# Full paths to libraries
SDK_LIB_DIRETTA = $(SDK_PATH)/lib/$(DIRETTA_LIB_NAME)
SDK_LIB_ACQUA   = $(SDK_PATH)/lib/$(ACQUA_LIB_NAME)

ifeq (,$(wildcard $(SDK_LIB_DIRETTA)))
    $(info )
    $(info ❌ Required library not found: $(DIRETTA_LIB_NAME))
    $(info    Path checked: $(SDK_LIB_DIRETTA))
    $(info )
    $(info 📝 Available libraries in SDK:)
    $(info $(shell ls -1 $(SDK_PATH)/lib/libDirettaHost_*.a 2>/dev/null | sed 's|.*/libDirettaHost_||' | sed 's|\.a||' || echo "    No libraries found"))
    $(info )
    $(info 💡 Common solutions:)
    $(info )
    $(info   For Raspberry Pi:)
    $(info     make ARCH_NAME=aarch64-linux-15)
    $(info )
    $(info   For x64 systems:)
    $(info     make ARCH_NAME=x64-linux-15v2       # Baseline)
    $(info     make ARCH_NAME=x64-linux-15v3       # AVX2 (most common))
    $(info     make ARCH_NAME=x64-linux-15v4       # AVX512)
    $(info     make ARCH_NAME=x64-linux-15zen4     # AMD Ryzen 7000+)
    $(info )
    $(info   For RISC-V:)
    $(info     make ARCH_NAME=riscv64-linux-15)
    $(info )
    $(info   Or run: make list-variants)
    $(info )
    $(error Build failed: library not found)
endif

ifeq (,$(wildcard $(SDK_LIB_ACQUA)))
    $(warning ⚠️  ACQUA library not found: $(ACQUA_LIB_NAME))
endif

SDK_HEADER = $(SDK_PATH)/Host/Diretta/SyncBuffer
ifeq (,$(wildcard $(SDK_HEADER)))
    $(error ❌ SDK headers not found at: $(SDK_PATH)/Host/)
endif

$(info ✓ SDK validation passed)
$(info )

# ============================================
# Include and Library Paths
# ============================================

INCLUDES = \
    -I/usr/include/ffmpeg \
    -I/usr/include/upnp \
    -I/usr/local/include \
    -I. \
    -I$(SDK_PATH)/Host

LDFLAGS += \
    -L/usr/local/lib \
    -L$(SDK_PATH)/lib

LIBS = \
    -lupnp \
    -lixml \
    -lpthread \
    -lDirettaHost_$(FULL_VARIANT)$(NOLOG_SUFFIX) \
    -lavformat \
    -lavcodec \
    -lavutil \
    -lswresample

ifneq (,$(wildcard $(SDK_LIB_ACQUA)))
    LIBS += -lACQUA_$(FULL_VARIANT)$(NOLOG_SUFFIX)
    $(info ✓ ACQUA library will be linked)
endif

# ============================================
# Source Files
# ============================================

SRCDIR = src
OBJDIR = obj
BINDIR = bin

SOURCES = \
    $(SRCDIR)/main.cpp \
    $(SRCDIR)/DirettaRenderer.cpp \
    $(SRCDIR)/AudioEngine.cpp \
    $(SRCDIR)/DirettaOutput.cpp \
    $(SRCDIR)/UPnPDevice.cpp

OBJECTS = $(SOURCES:$(SRCDIR)/%.cpp=$(OBJDIR)/%.o)
DEPENDS = $(OBJECTS:.o=.d)

TARGET = $(BINDIR)/DirettaRendererUPnP

# ============================================
# Build Rules
# ============================================

.PHONY: all clean info help list-variants examples list-sdks

all: $(TARGET)
	@echo ""
	@echo "✓ Build complete: $(TARGET)"
	@echo "✓ Using SDK version: $(SDK_VERSION)"
	@echo "✓ Using library: $(DIRETTA_LIB_NAME)"

$(TARGET): $(OBJECTS) | $(BINDIR)
	@echo "Linking $(TARGET)..."
	$(CXX) $(OBJECTS) $(LDFLAGS) $(LIBS) -o $(TARGET)

$(OBJDIR)/%.o: $(SRCDIR)/%.cpp | $(OBJDIR)
	@echo "Compiling $<..."
	$(CXX) $(CXXFLAGS) $(INCLUDES) -MMD -MP -c $< -o $@

$(OBJDIR):
	@mkdir -p $(OBJDIR)

$(BINDIR):
	@mkdir -p $(BINDIR)

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(OBJDIR) $(BINDIR)
	@echo "✓ Clean complete"

# ============================================
# Information Commands
# ============================================

info:
	@echo "════════════════════════════════════════════════════════"
	@echo " Diretta UPnP Renderer - Detailed Configuration"
	@echo "════════════════════════════════════════════════════════"
	@echo ""
	@echo "System:"
	@echo "  uname -m:     $(UNAME_M)"
	@echo "  Base Arch:    $(BASE_ARCH)"
	@echo ""
	@echo "Selected:"
	@echo "  Variant:      $(FULL_VARIANT)"
	@echo "  Library:      $(DIRETTA_LIB_NAME)"
	@echo "  No-Log:       $(if $(NOLOG),Yes,No)"
	@echo ""
	@echo "SDK:"
	@echo "  Path:         $(SDK_PATH)"
	@echo "  Version:      $(SDK_VERSION)"
	@echo "  Diretta Lib:  $(SDK_LIB_DIRETTA)"
	@echo "  ACQUA Lib:    $(SDK_LIB_ACQUA)"
	@echo ""
	@echo "Build:"
	@echo "  Compiler:     $(CXX)"
	@echo "  Target:       $(TARGET)"
	@echo ""
	@echo "════════════════════════════════════════════════════════"

list-sdks:
	@echo "════════════════════════════════════════════════════════"
	@echo " Installed Diretta SDK Versions"
	@echo "════════════════════════════════════════════════════════"
	@echo ""
	@find $(HOME) . .. /opt $(HOME)/audio /usr/local \
		-maxdepth 1 -type d -name 'DirettaHostSDK_*' 2>/dev/null | \
		while read sdk; do \
			version=$$(basename $$sdk | sed 's/DirettaHostSDK_//'); \
			echo "  ✓ $$sdk (version $$version)"; \
		done | sort -V || echo "  ❌ No SDK found"
	@echo ""
	@echo "Currently using: $(SDK_PATH) (version $(SDK_VERSION))"
	@echo ""
	@echo "════════════════════════════════════════════════════════"

list-variants:
	@echo "════════════════════════════════════════════════════════"
	@echo " Available Libraries in SDK"
	@echo "════════════════════════════════════════════════════════"
	@echo ""
	@echo "SDK: $(SDK_PATH)"
	@echo ""
	@echo "Available variants:"
	@ls -1 $(SDK_PATH)/lib/libDirettaHost_*.a 2>/dev/null | \
		sed 's|.*/libDirettaHost_||' | sed 's|\.a||' | sed 's|^|  ✓ |' || \
		echo "  ❌ No libraries found"
	@echo ""
	@echo "════════════════════════════════════════════════════════"

examples:
	@echo "════════════════════════════════════════════════════════"
	@echo " Build Examples"
	@echo "════════════════════════════════════════════════════════"
	@echo ""
	@echo "Auto-detection (recommended):"
	@echo "  make"
	@echo ""
	@echo "Manual override for Raspberry Pi:"
	@echo "  make ARCH_NAME=aarch64-linux-15"
	@echo "  make ARCH_NAME=aarch64-linux-15k16"
	@echo ""
	@echo "Manual override for x64:"
	@echo "  make ARCH_NAME=x64-linux-15v2       # Baseline (SSE4)"
	@echo "  make ARCH_NAME=x64-linux-15v3       # AVX2 (most common)"
	@echo "  make ARCH_NAME=x64-linux-15v4       # AVX512"
	@echo "  make ARCH_NAME=x64-linux-15zen4     # AMD Zen 4"
	@echo ""
	@echo "Manual override for RISC-V:"
	@echo "  make ARCH_NAME=riscv64-linux-15"
	@echo ""
	@echo "Disable logging (any architecture):"
	@echo "  make ARCH_NAME=x64-linux-15v3 NOLOG=1"
	@echo "  make ARCH_NAME=aarch64-linux-15 NOLOG=1"
	@echo ""
	@echo "Custom SDK location:"
	@echo "  make DIRETTA_SDK_PATH=/custom/path/DirettaHostSDK_150"
	@echo ""
	@echo "════════════════════════════════════════════════════════"

help:
	@echo "Diretta UPnP Renderer - Makefile"
	@echo ""
	@echo "Commands:"
	@echo "  make              Auto-detect architecture and SDK version, then build"
	@echo "  make clean        Remove build artifacts"
	@echo "  make info         Show detailed configuration"
	@echo "  make list-sdks    List all installed SDK versions"
	@echo "  make list-variants List all library variants in current SDK"
	@echo "  make examples     Show build command examples"
	@echo "  make help         Show this help"
	@echo ""
	@echo "Options:"
	@echo "  ARCH_NAME=<variant>  Manually specify library variant"
	@echo "  NOLOG=1              Use -nolog version"
	@echo "  DIRETTA_SDK_PATH=<path>  Custom SDK location"
	@echo ""
	@echo "SDK Auto-Detection:"
	@echo "  The Makefile automatically finds the latest DirettaHostSDK_* version"
	@echo "  Works with any version: 148, 149, 150, etc."
	@echo ""
	@echo "Common usage:"
	@echo ""
	@echo "  Raspberry Pi:"
	@echo "    make ARCH_NAME=aarch64-linux-15"
	@echo ""
	@echo "  x64 PC with AVX2:"
	@echo "    make ARCH_NAME=x64-linux-15v3"
	@echo ""
	@echo "  Auto-detect everything:"
	@echo "    make"
	@echo ""
	@echo "For more: make examples"

-include $(DEPENDS)
