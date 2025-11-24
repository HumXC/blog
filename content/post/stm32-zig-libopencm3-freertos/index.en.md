---
title: "Driving STM32 with Zig: Bare-Metal Development Using libopencm3 and FreeRTOS"
date: "2025-11-20T09:33:52+08:00"
draft: false
author: "HumXC"
slug: "stm32-zig-libopencm3-freertos"
description: "Writing Zig code for STM32 using libopencm3 and FreeRTOS to blink an LED"
tags:
  - Zig
  - STM32
  - libopencm3
  - FreeRTOS
  - Embedded
image: "Cover.png"
---

To build some small gadgets, I decided to try programming an STM32 microcontroller using Zig. I went with the popular and inexpensive STM32F103C8T6 (the classic “Blue Pill”), bought a dev board and an ST-Link/V2 debugger. This article documents my journey of getting Zig to run on STM32, using **libopencm3** for hardware abstraction and **FreeRTOS** for task scheduling — all culminating in the timeless “blink an LED” demo.

This project was my first deep dive into both Zig and the embedded world, and also my first time touching an STM32.

> Useful links:
>
> - [Zig](https://ziglang.org/)
> - [libopencm3](https://github.com/libopencm3/libopencm3)
> - [FreeRTOS](https://www.freertos.org/)
> - [My Project Repository](https://github.com/HumXC/zig_stm32_libopencm3_freertos.git)
> - [Zig STM32 Blink by rbino](https://rbino.com/posts/zig-stm32-blink/) (huge thanks — this post saved me!)

## Why Zig?

Embedded language choices are limited. Apart from C/C++, we have Rust, TinyGo, etc. I’ve been using Zig for over six months and really enjoy it. Compared to Go (my most familiar language), manual memory management is indeed more verbose, but Zig’s ability to call C libraries with almost zero friction is a game-changer in many domains. Zig also ships with an extremely flexible build system — everything lives in a single `build.zig` file, which feels incredibly clean.

I assume you have at least basic Zig knowledge. The full source code for everything described here is linked at the top.

## Basic Project Setup

Create a normal Zig project and configure the target for your MCU in `build.zig`:

```zig
const target = b.resolveTargetQuery(.{
    .abi = .eabi,
    .cpu_arch = .thumb,
    .os_tag = .freestanding,
    .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m3 },
});

const elf = b.addExecutable(.{
    .name = "zig-stm32",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .strip = !debug,
    }),
});

elf.link_data_sections = true;
elf.link_function_sections = true;
elf.link_gc_sections = true;
```

The above configuration is for the Cortex-M3 in the STM32F103. Change the CPU model if you’re using a different core.

## Bringing in libopencm3

If you’ve never used libopencm3 before, check its docs. Normally you’d clone the repo and run `make`. With Zig we can do it all from the build system.

Add the dependency in `build.zig.zon`:

```zig
.libopencm3 = .{
    .url = "git+https://github.com/libopencm3/libopencm3#5e7dc5d092e52bbfbb8b5929e2097732e1b7f81c",
    .hash = "1220a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6", // replace with real hash
},
```

Now write a helper that either returns an already-built static library or builds it on-the-fly:

```zig
pub fn getStaticLibrary(b: *std.Build, comptime target: []const u8) std.Build.LazyPath {
    const libopencm3 = b.dependency("libopencm3", .{});
    const slash_pos = std.mem.indexOf(u8, target, "/").?;
    const part1 = target[0..slash_pos];
    const part2 = target[slash_pos + 1 ..];
    const lib_name = b.fmt("libopencm3_{s}{s}.a", .{ part1, part2 });
    const lib_path = libopencm3.path(b.pathJoin(&.{ "lib", lib_name })).getPath(b);

    // If already built, just return it
    if (std.fs.openFileAbsolute(lib_path, .{})) |f| {
        f.close();
        return .{ .cwd_relative = lib_path };
    } else |_| {}

    const make = b.addSystemCommand(&.{ "make", "-C" });
    make.addDirectoryArg(libopencm3.path("."));
    make.addArg(b.fmt("TARGETS={s}", .{target}));

    const generated = b.allocator.create(std.Build.GeneratedFile) catch @panic("OOM");
    generated.* = .{ .step = &make.step, .path = lib_path };
    return .{ .generated = .{ .file = generated } };
}
```

Link it:

```zig
elf.addObjectFile(getStaticLibrary(b, "stm32/f1"));
elf.addLibraryPath(libopencm3.path("lib"));
elf.addIncludePath(libopencm3.path("include"));
```

### Linker Script

libopencm3 provides a generic Cortex-M script that needs ROM/RAM regions filled in. Here’s a helper that patches it at build time:

```zig
pub const MemoryRegion = struct { origin: u32, length: u32 };

pub fn getLinkScript(b: *std.Build, rom: MemoryRegion, ram: MemoryRegion) std.Build.LazyPath {
    const libopencm3 = b.dependency("libopencm3", .{});
    const generic = libopencm3.path("lib/cortex-m-generic.ld").getPath(b);
    const content = std.fs.readFileAlloc(b.allocator, generic, std.math.maxInt(usize)) catch unreachable;

    const patched = b.fmt(
        \\MEMORY
        \\{{
        \\  rom (rx) : ORIGIN = 0x{x}, LENGTH = {d}K
        \\  ram (rwx) : ORIGIN = 0x{x}, LENGTH = {d}K
        \\}}
        \\
    , .{ rom.origin, rom.length / 1024, ram.origin, ram.length / 1024 }) ++ content;

    const wf = b.addWriteFiles();
    return wf.add("linker.ld", patched);
}
```

Use it:

```zig
elf.setLinkerScript(getLinkScript(b,
    .{ .origin = 0x08000000, .length = 64 * 1024 }, // 64 KiB Flash
    .{ .origin = 0x20000000, .length = 20 * 1024 }, // 20 KiB RAM
));
```

### First Blink (no RTOS yet)

```zig
const hal = @cImport({
    @cDefine("STM32F1", "1");
    @cInclude("libopencm3/stm32/rcc.h");
    @cInclude("libopencm3/stm32/gpio.h");
});

export fn _start() callconv(.C) void {
    main();
}

pub export fn main() callconv(.C) void {
    hal.rcc_clock_setup_in_hse_8mhz_out_72mhz();

    hal.rcc_periph_clock_enable(hal.RCC_GPIOC);
    hal.gpio_set_mode(hal.GPIOC, hal.GPIO_MODE_OUTPUT_2_MHZ,
        hal.GPIO_CNF_OUTPUT_PUSHPULL, hal.GPIO13);

    hal.gpio_set(hal.GPIOC, hal.GPIO13); // LED off (active low on Blue Pill)

    while (true) {}
}
```

### Generate a .bin for flashing

```zig
const bin = elf.addObjCopy(.{ .format = .bin });
const install_bin = b.addInstallBinFile(bin.getOutput(), "firmware.bin");
b.getInstallStep().dependOn(&install_bin.step);
```

Run `zig build` → `zig-out/bin/firmware.bin` → flash with `st-flash write zig-out/bin/firmware.bin 0x8000000`

## Adding FreeRTOS

Add the kernel as a dependency:

```zig
.freertos = .{
    .url = "https://github.com/FreeRTOS/FreeRTOS-Kernel/releases/download/V11.2.0/FreeRTOS-KernelV11.2.0.zip",
    .hash = "1220...", // actual hash
},
```

### FreeRTOSConfig.h

Grab the template, then make two critical changes for Zig:

```c
#define configCHECK_HANDLER_INSTALLATION 0

// At the very end, before #endif
#define vPortSVCHandler   SVC_Handler
#define xPortPendSVHandler PendSV_Handler
#define xPortSysTickHandler SysTick_Handler
```

Place `FreeRTOSConfig.h` somewhere (e.g. `src/`) and add the include path.

### Libc headers (needed by FreeRTOS)

I just pointed to the `arm-none-eabi` headers from the GNU Arm Embedded Toolchain:

```zig
elf.addIncludePath(.{ .cwd_relative = "/path/to/arm-none-eabi/include" });
```

### Add FreeRTOS sources

```zig
const freertos = b.dependency("freertos", .{});

elf.addIncludePath(freertos.path("include"));
elf.addIncludePath(freertos.path("portable/GCC/ARM_CM3"));

elf.addCSourceFiles(.{
    .files = &.{
        freertos.path("tasks.c").getPath(b),
        freertos.path("queue.c").getPath(b),
        freertos.path("list.c").getPath(b),
        freertos.path("timers.c").getPath(b),
        freertos.path("event_groups.c").getPath(b),
        freertos.path("stream_buffer.c").getPath(b),
        freertos.path("croutine.c").getPath(b),
        freertos.path("portable/MemMang/heap_4.c").getPath(b),
        freertos.path("portable/GCC/ARM_CM3/port.c").getPath(b),
    },
    .flags = &.{ "-Wno-everything" }, // silence warnings from upstream
});
```

### Final main.zig with FreeRTOS

```zig
const hal = @cImport({
    @cDefine("STM32F1", "1");
    @cInclude("libopencm3/stm32/rcc.h");
    @cInclude("libopencm3/stm32/gpio.h");
});

const os = @cImport({
    @cInclude("FreeRTOS.h");
    @cInclude("task.h");
});

fn led_task(_: ?*anyopaque) callconv(.C) void {
    hal.rcc_clock_setup_in_hse_8mhz_out_72mhz();
    hal.rcc_periph_clock_enable(hal.RCC_GPIOC);
    hal.gpio_set_mode(hal.GPIOC, hal.GPIO_MODE_OUTPUT_2_MHZ,
        hal.GPIO_CNF_OUTPUT_PUSHPULL, hal.GPIO13);

    while (true) {
        hal.gpio_toggle(hal.GPIOC, hal.GPIO13);
        os.vTaskDelay(500); // 500 ms
    }
}

export fn main() callconv(.C) void {
    _ = os.xTaskCreate(led_task, "LED", 128, null, 1, null);
    os.vTaskStartScheduler();

    unreachable; // scheduler never returns
}
```

That’s it! `zig build` → flash → watch the onboard LED blink under FreeRTOS control, all written and built with Zig.

## Closing Thoughts

Zig’s ability to seamlessly consume existing C ecosystem libraries (libopencm3, FreeRTOS) while still giving you fine-grained control over the build process makes it surprisingly pleasant for bare-metal work. The learning curve exists, but once the build glue is in place, development feels very smooth.

Happy hacking, and may your LEDs always blink on the first try! 🚀
