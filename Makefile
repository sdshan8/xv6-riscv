ARCH    ?= riscv64
HOSTCC  ?= cc
CC      := clang
AS      := $(CC)
LD      := ld.lld
OBJCOPY := llvm-objcopy
OBJDUMP := llvm-objdump
QEMU    := qemu-system-$(ARCH)
MIN_QEMU_VERSION = 7.2

K := kernel
U := user
ARCHDIR := $K/arch/$(ARCH)
BUILD   := build/$(ARCH)
KERNEL  := $(BUILD)/kernel.elf

ARCH_OBJS = \
  $(ARCHDIR)/entry.o \
  $(ARCHDIR)/start.o \
  $(ARCHDIR)/swtch.o \
  $(ARCHDIR)/trampoline.o \
  $(ARCHDIR)/kernelvec.o \
  $(ARCHDIR)/plic.o

OBJS = $(ARCH_OBJS) \
  $K/console.o $K/printk.o $K/uart.o $K/kalloc.o $K/spinlock.o \
  $K/string.o $K/main.o $K/vm.o $K/proc.o $K/trap.o $K/syscall.o \
  $K/sysproc.o $K/bio.o $K/fs.o $K/log.o $K/sleeplock.o $K/file.o \
  $K/pipe.o $K/exec.o $K/sysfile.o $K/virtio_disk.o

ifeq ($(ARCH),riscv64)
  ARCHFLAGS := --target=riscv64-unknown-elf -march=rv64gc -mabi=lp64 -mcmodel=medany
  QEMUMACH  := -machine virt -bios none
else ifeq ($(ARCH),aarch64)
  ARCHFLAGS := --target=aarch64-unknown-elf -mstrict-align -mcmodel=small
  QEMUMACH  := -machine virt,gic-version=2 -cpu cortex-a72
else
  $(error Unknown ARCH '$(ARCH)')
endif

COMMON := $(ARCHFLAGS) -std=gnu99 -O2 -g -ffreestanding -fno-builtin -fno-common \
          -fno-pie -fno-stack-protector -fno-omit-frame-pointer \
          -Wall -Wextra -Wno-unknown-attributes -Wno-main \
          -Werror=incompatible-pointer-types -MD \
          -ffile-prefix-map=$(CURDIR)=.

KCFLAGS := $(COMMON) -I. -Ishared -I$K -I$(ARCHDIR) -Ishared/arch/$(ARCH)
UCFLAGS := $(COMMON) -Os -ffunction-sections -fdata-sections \
           -Ishared -Ishared/arch/$(ARCH) -Iuser
ASFLAGS := $(KCFLAGS)
LDFLAGS  = -z max-page-size=4096
ULDFLAGS = -z max-page-size=4096 -e main --strip-debug --no-rosegment
ULDFLAGS += --gc-sections --image-base=0x0

KOBJS := $(addprefix $(BUILD)/,$(OBJS))
ULIB  := $(addprefix $(BUILD)/user/,ulib.o usys.o printf.o umalloc.o)

# ---- compile rules ----------------------------------------------------
$(BUILD)/kernel/%.o: kernel/%.c
	@mkdir -p $(@D)
	$(CC) $(KCFLAGS) -c -o $@ $<

$(BUILD)/kernel/%.o: kernel/%.S
	@mkdir -p $(@D)
	$(CC) $(ASFLAGS) -c -o $@ $<

$(BUILD)/user/%.o: user/%.c
	@mkdir -p $(@D)
	$(CC) $(UCFLAGS) -c -o $@ $<

$(BUILD)/user/%.o: $(BUILD)/user/%.S
	$(CC) $(UCFLAGS) -c -o $@ $<

$(BUILD)/user/usys.S: user/usys.pl
	@mkdir -p $(@D)
	perl $< > $@

# ---- kernel -----------------------------------------------------------
$(KERNEL): $(KOBJS) $(ARCHDIR)/kernel.ld
	$(LD) $(LDFLAGS) -T $(ARCHDIR)/kernel.ld -o $@ $(KOBJS)
	$(OBJDUMP) -S $@ > $(BUILD)/kernel.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $(BUILD)/kernel.sym

# ---- user programs ----------------------------------------------------
$(BUILD)/user/_%: $(BUILD)/user/%.o $(ULIB) user/user.ld
	$(LD) $(ULDFLAGS) -T user/user.ld -o $@ $< $(ULIB)
	$(OBJDUMP) -S $@ > $(BUILD)/user/$*.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $(BUILD)/user/$*.sym

$(BUILD)/user/_forktest: $(BUILD)/user/forktest.o $(ULIB)
	$(LD) $(ULDFLAGS) -N -e main -Ttext 0 -o $@ $< \
	  $(BUILD)/user/ulib.o $(BUILD)/user/usys.o
	$(OBJDUMP) -S $@ > $(BUILD)/user/forktest.asm

UPROGS := $(addprefix $(BUILD)/user/_,cat echo forktest grep init kill ln ls \
  mkdir rm sh stressfs usertests grind wc zombie logstress forphan dorphan sync)

# ---- host tool and disk image ----------------------------------------
$(BUILD)/mkfs: mkfs/mkfs.c shared/fs.h shared/param.h shared/types.h shared/stat.h
	@mkdir -p $(@D)
	$(HOSTCC) -Wno-unknown-attributes -iquote shared -o $@ mkfs/mkfs.c

$(BUILD)/fs.img: $(BUILD)/mkfs README $(UPROGS)
	$(BUILD)/mkfs $@ README $(UPROGS)

.PRECIOUS: $(BUILD)/%.o $(BUILD)/user/usys.S

-include $(shell find $(BUILD) -name '*.d' 2>/dev/null)

clean:
	rm -rf $(BUILD) .gdbinit

# try to generate a unique GDB port
GDBPORT = $(shell expr `id -u` % 5000 + 25000)
# QEMU's gdb stub command line changed in 0.11
QEMUGDB = $(shell if $(QEMU) -help | grep -q '^-gdb'; \
	then echo "-gdb tcp::$(GDBPORT)"; \
	else echo "-s -p $(GDBPORT)"; fi)
ifndef CPUS
CPUS := 3
endif

QEMUOPTS = $(QEMUMACH) -kernel $(KERNEL) -m 128M -smp $(CPUS) -nographic
QEMUOPTS += -global virtio-mmio.force-legacy=false
QEMUOPTS += -drive file=$(BUILD)/fs.img,if=none,format=raw,id=x0
QEMUOPTS += -device virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0

qemu: check-qemu-version $(KERNEL) $(BUILD)/fs.img
	$(QEMU) $(QEMUOPTS)

.gdbinit: .gdbinit.tmpl-$(ARCH)
	sed "s/:1234/:$(GDBPORT)/" < $^ > $@
  
qemu-gdb: $(KERNEL) .gdbinit $(BUILD)/fs.img
	@echo "*** Now run 'gdb' in another window." 1>&2
	$(QEMU) $(QEMUOPTS) -S $(QEMUGDB)


print-gdbport:
	@echo $(GDBPORT)

QEMU_VERSION := $(shell $(QEMU) --version | head -n 1 | sed -E 's/^QEMU emulator version ([0-9]+\.[0-9]+)\..*/\1/')
check-qemu-version:
	@if [ "$(shell echo "$(QEMU_VERSION) >= $(MIN_QEMU_VERSION)" | bc)" -eq 0 ]; then \
		echo "ERROR: Need qemu version >= $(MIN_QEMU_VERSION)"; \
		exit 1; \
	fi

.PHONY: fmt
fmt:
	clang-format -i $(wildcard kernel/*.[ch] user/*.[ch] mkfs/*.c)
