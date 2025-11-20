---
title: 'Zig 驱动 STM32：基于 libopencm3 与 FreeRTOS 的裸机开发体验'
date: "2025-11-20T09:33:52+08:00"
draft: true
author: "HumXC"
slug: "stm32-zig-libopencm3-freertos"
description: "在 STM32 上使用 Zig 编写代码，基于 libopencm3 与 FreeRTOS 来闪烁 LED"
tags:
  - Zig
  - STM32
  - libopencm3
  - FreeRTOS
  - Embedded
aliases:
image: "Cover.png"
---
为了制作一些玩具，我开始尝试使用 Zig 在 STM32 上编程。我选择了常见且便宜的 STM32F103C8T6，买好了开发板和 ST-Link/V2 调试器。本文将分享在 STM32 上使用 Zig 编写代码，基于 libopencm3 与 FreeRTOS 来闪烁 LED 的过程。制作这个项目也是我在 Zig 和 "嵌入式领域" 的一次探索，这也是我第一次使用 STM32。

> 一些链接:
>
> - [Zig](https://ziglang.org/)
> - [libopencm3](https://github.com/libopencm3/libopencm3)
> - [FreeRTOS](https://www.freertos.org/)
> - [My Project](https://github.com/HumXC/zig_stm32_libopencm3_freertos.git)
> - [Zig Stm32 Blink](https://rbino.com/posts/zig-stm32-blink/)
>

## 为什么选择 Zig？

嵌入式语言的选择并不多，除了 C/C++ 之外，还有 Rust, TinyGo 等等。我接触 Zig 已经大半年了，我很喜欢 Zig，虽然对比我最熟悉的 Go 语言来说，手动管理内存确实繁琐，但可以非常简单地调用 C 库，这在某些领域的开发上为我带来了极大的便利。Zig 还有非常灵活的构建系统，构建过程都可以塞进 `build.zig` 文件中，非常方便。

在开始之前，我假设你对 Zig 有一定了解，在本文顶部我放置了本文提到的项目的链接，你可以从那里找到项目的源码。

感谢 rbino 的文章为我指点迷津，你可以在顶部找到他的博客链接。

## 基本配置

创建一个基本的 Zig 项目，创建一个匹配目标芯片的 elf 编辑 `build.zig` 文件：

```zig
const target = b.resolveTargetQuery(.{
    .abi = .eabi,
    .cpu_arch = .thumb,
    .os_tag = .freestanding,
    .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m3 },
});

const elf = b.addExecutable(.{
    .name = name,
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

参考 rbion 的博客，这是我使用的芯片的配置，如果你使用其他芯片，请按照你的芯片的实际配置来修改。

## 导入 libopencm3

如果你也跟我一样没有接触过 libopencm3，可以看看他的文档，克隆他的仓库，在仓库中执行 `make` 命令就能生成我们需要的库文件。现在我们使用 Zig 完成这一切。

编辑 `build.zig.zon`：

```zig
.{
    ...
    .dependencies = .{
        .libopencm3 = .{
            .url = "git+https://github.com/libopencm3/libopencm3#5e7dc5d092e52bbfbb8b5929e2097732e1b7f81c",
            .hash = "N-V-__8AAPMXXgAQa5KZISzTTuLJyAhrAPA88Gm8xyInun4J",
        },
        ...
    },
    ...
}
```

现在 libopencm3 在 `build.zig` 中可用了，我们可以开始编写代码了。

```zig
pub fn getStaticLibrary(b: *std.Build, comptime target: []const u8) std.Build.LazyPath {
    const libopencm3 = b.dependency("libopencm3", .{});

    const slash_pos = std.mem.indexOf(u8, target, "/").?;
    const part1 = target[0..slash_pos];
    const part2 = target[slash_pos + 1 ..];
    const lib_name = b.fmt("libopencm3_{s}{s}.a", .{ part1, part2 });
    const lib_path = libopencm3.path(b.pathJoin(&.{ "lib", lib_name })).getPath(b);

    {
        const f = std.fs.openFileAbsolute(lib_path, .{}) catch null;
        if (f) |file| {
            file.close();
            return .{ .cwd_relative = lib_path };
        }
    }

    const make_lib_cmd = b.addSystemCommand(&.{ "make", "-C" });
    make_lib_cmd.addDirectoryArg(libopencm3.path("."));
    make_lib_cmd.addArg(b.fmt("TARGETS={s}", .{target}));

    const output_file = b.allocator.create(std.Build.GeneratedFile) catch @panic("OOM");
    output_file.* = .{
        .step = &make_lib_cmd.step,
        .path = lib_path,
    };
    return .{ .generated = .{ .file = output_file } };
}
```

我编写了这个函数，他可以返回构建出来的 `.a` 文件的路径。现在我们将其链接到 elf 中并添加其他导入路径

```zig
const libopencm3 = b.dependency("libopencm3", .{});
elf.addObjectFile(getStaticLibrary(b, "stm32/f1"));
elf.addLibraryPath(libopencm3.path("lib"));
elf.addIncludePath(libopencm3.path("include"));
```

我们还需要导入 libopencm3 的链接器脚本，他在 `lib/cortex-m-generic.ld` 中，根据其中的注释，我们还需要声明 `rom` 和 `ram` 的内存区域。我写了下面的函数生成链接脚本：

```zig
pub const MemoryRegion = struct {
    origin: u32,
    length: u32,
};

pub fn getLinkScript(b: *std.Build, rom: MemoryRegion, ram: MemoryRegion) std.Build.LazyPath {
    const libopencm3 = b.dependency("libopencm3", .{});
    const generic_ld_path = libopencm3.path("lib/cortex-m-generic.ld").getPath(b);
    var file = std.fs.openFileAbsolute(generic_ld_path, .{}) catch unreachable;

    var result: std.Io.Writer.Allocating = .init(b.allocator);
    result.writer.writeAll(b.fmt(
        \\MEMORY
        \\{{
        \\    rom (rx) : ORIGIN = 0x{x}, LENGTH = {d}
        \\    ram (rwx)  : ORIGIN = 0x{x}, LENGTH = {d}
        \\}}
    , .{
        rom.origin,
        rom.length,
        ram.origin,
        ram.length,
    })) catch unreachable;

    result.writer.writeAll(file.readToEndAlloc(b.allocator, std.math.maxInt(usize)) catch unreachable) catch unreachable;

    const wf = b.addWriteFiles();
    return wf.add("linker.ld", result.toOwnedSlice() catch unreachable);
}
```

然后让 elf 使用这个脚本：

```zig
elf.setLinkerScript(getLinkScript(
    b,
    .{
        .origin = 0x08000000,
        .length = 64 * 1024,
    },
    .{
        .origin = 0x20000000,
        .length = 20 * 1024,
    },
));
```

现在你可以该可以在 `src/main.zig` 中导入和使用 libopencm3 的函数了。

```zig
const hal = @cImport({
    @cDefine("STM32F1", "1");
    @cInclude("libopencm3/stm32/rcc.h");
    @cInclude("libopencm3/stm32/gpio.h");
});

// 重写启动入口
export fn _start() callconv(.c) void {
    main();
    unreachable;
}

// 主程序
export fn main() callconv(.c) void {
    // 设置系统时钟为 72MHz
    hal.rcc_clock_setup_in_hse_8mhz_out_72mhz();
    // 打开 GPIOC 时钟
    hal.rcc_periph_clock_enable(hal.RCC_GPIOC);

    // 设置 PC13 推挽输出
    hal.gpio_set_mode(
        hal.GPIOC,
        hal.GPIO_MODE_OUTPUT_2_MHZ,
        hal.GPIO_CNF_OUTPUT_PUSHPULL,
        hal.GPIO13,
    );
    // 熄灭 LED
    hal.gpio_set(hal.GPIOC, hal.GPIO13);
    while (true) {};
}

```

## 构建和刷入

还需要将 elf 转为能够直接刷写进 STM32 的 bin 文件，使用以下代码：

```zig
const bin = elf.addObjCopy(.{ .format = .bin });
const bin_output = b.addInstallBinFile(bin.getOutput(), "bin");
b.getInstallStep().dependOn(&bin_output.step);
```

执行 `zig build` 编译项目，应该能在 `zig-cache/bin` 目录下找到 `bin` 文件。可以使用 `st-flash` 工具将其刷入 STM32。

## 导入 FreeRTOS

类似的，先让 Zig 获取 FreeRTOS 的源码，在 `build.zig.zon` 中添加依赖：

```zig
.freertos = .{
    .url = "https://github.com/FreeRTOS/FreeRTOS-Kernel/releases/download/V11.2.0/FreeRTOS-KernelV11.2.0.zip",
    .hash = "N-V-__8AABBQEQEqOzP-h5Nz5cgduMAUVp4TMn1BadkEWiam",
}
```

首先，需要准备 `FreeRTOSConfig.h`, 可以从 [这里](https://github.com/FreeRTOS/FreeRTOS-Kernel/blob/main/examples/template_configuration/FreeRTOSConfig.h) 获取模板，然后根据实际情况进行修改。

特别的，将 `configCHECK_HANDLER_INSTALLATION` 设为 `0`，否则 FreeRTOS 会无法正常运行。

```c
#define configCHECK_HANDLER_INSTALLATION 0
```

最后在 `FreeRTOSConfig.h` 的底部 `#endif` 之前加上：

```c
#define vPortSVCHandler sv_call_handler
#define xPortPendSVHandler pend_sv_handler
#define xPortSysTickHandler sys_tick_handler
#endif /* FREERTOS_CONFIG_H */
```

将 `FreeRTOSConfig.h` 放到你喜欢的目录下，并在 `build.zig` 中添加：

```zig
elf.addIncludePath(b.path("<dir to FreeRTOSConfig.h>"));
```

FreeRTOS 还需要导入 `Libc` 的头文件，这里我使用 `gcc-arm-embedded` 包中提供的 `arm-none-eabi` 的头文件，因为正好 libopencm3 也依赖 `gcc-arm-embedded`。在 `build.zig` 中添加：

```zig
elf.addIncludePath(.{ .cwd_relative = "<path to arm-none-eabi/include" });
```

还差最后一步就万事大吉了，导入 FreeRTOS 的头文件和 C 文件:

```zig
const freertos = b.dependency("freertos", .{});

elf.addIncludePath(freertos.path("portable/GCC/ARM_CM3"));
elf.addIncludePath(freertos.path("include"));
elf.addCSourceFile(.{ .file = freertos.path("portable/MemMang/heap_4.c") });
elf.addCSourceFile(.{ .file = freertos.path("portable/GCC/ARM_CM3/port.c") });
elf.addCSourceFile(.{ .file = freertos.path("tasks.c") });
elf.addCSourceFile(.{ .file = freertos.path("list.c") });
elf.addCSourceFile(.{ .file = freertos.path("queue.c") });
elf.addCSourceFile(.{ .file = freertos.path("timers.c") });
elf.addCSourceFile(.{ .file = freertos.path("event_groups.c") });
elf.addCSourceFile(.{ .file = freertos.path("stream_buffer.c") });
elf.addCSourceFile(.{ .file = freertos.path("croutine.c") });
```

`portable/GCC/ARM_CM3` 和 `portable/GCC/ARM_CM3/port.c` 需要根据实际的芯片架构进行修改。

最后，在 `main.zig` 中使用 FreeRTOS 的函数：

```zig
const os = @cImport({
    @cInclude("FreeRTOS.h");
    @cInclude("task.h");
});

_ = os.xTaskCreate(
    led_task,
    "LED",
    128,
    null,
    1,
    null,
);

os.vTaskStartScheduler();
```

一切都完成了，开始享受吧！
