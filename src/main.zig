const builtin = @import("builtin");
const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;
const File = fs.File;

const VIRTUAL_SECTOR_SIZE: u32 = 512;
const SECTOR_SIZE: u32 = 2048;
const BOOT_SECTOR: u32 = 17;

const FormatError = error{
    BadBootRecordIndicator,
    BadIso9660Identifier,
    BadBootSystemIdentifier,
    BadHeaderValue,
    BadReservedZeroValue,
    Bad55Checksum,
    BadAAChecksum,
    BadBootMediaType,
};

const WriteError = error{ReadEarlyExitError};

fn readIntSliceNative(comptime T: type, buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    const native_endian = builtin.cpu.arch.endian();
    return mem.readInt(T, buffer, native_endian);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_iter = process.args();
    var set_output_file = false;
    var output_filename: ?[:0]const u8 = null;
    var iso_filename: ?[:0]const u8 = null;

    const args = try process.argsAlloc(allocator);
    const exe = args[0];
    while (args_iter.next()) |arg| {
        if (set_output_file) {
            output_filename = arg;
            set_output_file = false;
        } else if (mem.eql(u8, arg, "-h")) {
            return usage(exe);
        } else if (mem.eql(u8, arg, "-v")) {
            std.debug.print("v0\n", .{});
            return error.Invalid;
        } else if (mem.eql(u8, arg, "-o")) {
            set_output_file = true;
        } else {
            iso_filename = arg;
        }
    }

    if (iso_filename == null) {
        return usage(exe);
    }
    const cwd = fs.cwd();
    var iso_file = try cwd.openFile(iso_filename.?, .{});
    defer iso_file.close();

    var output_buffer: [VIRTUAL_SECTOR_SIZE]u8 = undefined;
    if (output_filename == null) {
        const stdout_handle = std.fs.File.stdout();
        var stdout_writer = stdout_handle.writer(&output_buffer);
        return writeImage(&iso_file, &stdout_writer.interface);
    }
    var output_file = try cwd.openFile(output_filename.?, .{ .mode = .write_only });
    var output_writer = output_file.writer(&output_buffer);
    defer output_file.close();
    return writeImage(&iso_file, &output_writer.interface);
}

fn usage(exe: []const u8) !void {
    @setEvalBranchQuota(1500);
    const str =
        \\{s} [-h] [-v] [-o outputfilename] cd-image
        \\Script will try to extract an El Torito image from a
        \\bootable CD (or cd-image) given by <cd-image> and write
        \\the data extracted to STDOUT or to a file.
        \\   -h:        Print this message.
        \\   -v:        Print version of this program.
        \\   -o <file>: Write extracted data to file <file> instead of STDOUT
        \\
    ;
    std.debug.print(str, .{exe});
    return;
}

fn unwrapArg(arg: anyerror![]u8) ![]u8 {
    return arg catch |err| {
        std.debug.print("Unable to parse command line: {s}\n", .{err});
        return err;
    };
}

fn writeImage(iso_file: *const File, output_file: *std.io.Writer) !void {
    var boot_entry: [VIRTUAL_SECTOR_SIZE]u8 = undefined;
    try iso_file.seekTo(BOOT_SECTOR * SECTOR_SIZE);
    const boot_entry_bytes = iso_file.read(boot_entry[0..]) catch |err| {
        std.debug.print("Unable to read boot sector: {s}\n", .{@errorName(err)});
        return err;
    };
    if (boot_entry_bytes != VIRTUAL_SECTOR_SIZE) {
        return error.ReadError;
    }

    // Specification: https://pdos.csail.mit.edu/6.828/2018/readings/boot-cdrom.pdf, Page 13/20
    const boot_indicator = boot_entry[0];
    const iso_identifier = boot_entry[1..6];
    const desc_version = boot_entry[6];
    const spec = boot_entry[7..39];
    const boot_catalog_ptr = readIntSliceNative(u32, boot_entry[71..75]);

    std.debug.print("==== Boot Record Volume ====\n", .{});
    std.debug.print("Boot Record Indicator: {d}\n", .{boot_indicator});
    std.debug.print("ISO 9660 identifier: {s}\n", .{iso_identifier});
    std.debug.print("Descriptor Version: {d}\n", .{desc_version});
    std.debug.print("Specification: {s}\n", .{spec});
    std.debug.print("Boot Catalog Pointer: {d}\n", .{boot_catalog_ptr});

    if (boot_indicator != 0) {
        return FormatError.BadBootRecordIndicator;
    }
    if (!mem.eql(u8, iso_identifier, "CD001")) {
        return FormatError.BadIso9660Identifier;
    }

    // mem.eql checks length equality and spec is 32 bytes while the string is 23.
    // the spec is zero-padded so we're using the slice for validation
    if (!mem.eql(u8, spec[0..23], "EL TORITO SPECIFICATION")) {
        return FormatError.BadBootSystemIdentifier;
    }

    var catalog_entry: [VIRTUAL_SECTOR_SIZE]u8 = undefined;
    try iso_file.seekTo(boot_catalog_ptr * SECTOR_SIZE);
    const catalog_entry_bytes = iso_file.read(catalog_entry[0..]) catch |err| {
        std.debug.print("Unable to read boot sector: {s}\n", .{@errorName(err)});
        return err;
    };
    if (catalog_entry_bytes != VIRTUAL_SECTOR_SIZE) {
        return error.ReadError;
    }

    // Specification: https://pdos.csail.mit.edu/6.828/2018/readings/boot-cdrom.pdf, Page 9/20
    const header = catalog_entry[0];
    const platform = catalog_entry[1];
    const reserved_zero = readIntSliceNative(u16, catalog_entry[2..4]);
    const manufacturer = catalog_entry[4..28];

    // TODO: sum of these two bytes are supposed to equal zero?
    // The original geteltorio ignores these bytes also so...
    // const checksum_zero = catalog_entry[28..30];

    const five = catalog_entry[30];
    const aa = catalog_entry[31];

    std.debug.print("==== Validation Entry ====\n", .{});
    std.debug.print("header: {X}\n", .{header});
    std.debug.print("platform: ", .{});
    switch (platform) {
        0 => std.debug.print("x86\n", .{}),
        1 => std.debug.print("PowerPC\n", .{}),
        2 => std.debug.print("Mac\n", .{}),
        else => std.debug.print("unknown\n", .{}),
    }
    std.debug.print("platform: {X}\n", .{platform});
    std.debug.print("reserved_zero: {X}\n", .{reserved_zero});
    std.debug.print("manufacturer: {s}\n", .{manufacturer});
    std.debug.print("five checksum: {X}\n", .{five});
    std.debug.print("aa checksum: {X}\n", .{aa});

    if (header != 1) {
        return error.BadHeaderValue;
    }
    if (reserved_zero != 0) {
        return error.BadReservedZeroValue;
    }
    if (five != 0x55) {
        return error.Bad55Checksum;
    }
    if (aa != 0xAA) {
        return error.BadAAChecksum;
    }

    // https://pdos.csail.mit.edu/6.828/2018/readings/boot-cdrom.pdf, Page 10/20
    const initial_entry: []u8 = catalog_entry[32..64];
    const bootable = initial_entry[0];
    const boot_media_type = initial_entry[1];
    const load_segment = readIntSliceNative(u16, initial_entry[2..4]);
    const system_type = initial_entry[4];
    const sector_count = readIntSliceNative(u16, initial_entry[6..8]);
    const image_start = readIntSliceNative(u32, initial_entry[8..12]);

    std.debug.print("==== Initial (default) Entry ====\n", .{});
    std.debug.print("bootable: {X}\n", .{bootable});
    std.debug.print("boot media type: {X}\n", .{boot_media_type});
    std.debug.print("load segment: {X}\n", .{load_segment});
    std.debug.print("system type: {X}\n", .{system_type});
    std.debug.print("sector count: {X}\n", .{sector_count});
    std.debug.print("image start: {d}\n", .{image_start});

    const real_count = switch (boot_media_type) {
        0 => blk: {
            std.debug.print("no boot media emulation found\n", .{});
            break :blk 0;
        },
        1 => blk: {
            std.debug.print("boot media type is: 1.2meg floppy\n", .{});
            break :blk (1200 * 1024) / VIRTUAL_SECTOR_SIZE;
        },
        2 => blk: {
            std.debug.print("boot media type is: 1.44meg floppy\n", .{});
            break :blk (1440 * 1024) / VIRTUAL_SECTOR_SIZE;
        },
        3 => blk: {
            std.debug.print("boot media type is: 2.88meg floppy\n", .{});
            break :blk (2880 * 1024) / VIRTUAL_SECTOR_SIZE;
        },
        4 => blk: {
            std.debug.print("boot media type is: hard disk\n", .{});
            var mbr_entry: [VIRTUAL_SECTOR_SIZE]u8 = undefined;
            try iso_file.seekTo(image_start * SECTOR_SIZE);
            _ = iso_file.read(mbr_entry[0..]) catch |err| {
                std.debug.print("Unable to read master boot record: {s}\n", .{@errorName(err)});
                return err;
            };
            if (catalog_entry_bytes != VIRTUAL_SECTOR_SIZE) {
                return error.ReadError;
            }
            const first_sector = readIntSliceNative(u32, mbr_entry[454..458]);
            const partition_size = readIntSliceNative(u32, mbr_entry[458..462]);

            std.debug.print("first_sector: {d}\n", .{first_sector});
            std.debug.print("partition_size: {d}\n", .{partition_size});

            break :blk first_sector + partition_size;
        },
        else => {
            std.debug.print("unknown boot media emulation found: {d}\n", .{boot_media_type});
            return error.BadBootMediaType;
        },
    };
    const count = if (real_count == 0) sector_count else real_count;
    std.debug.print("El Torito image starts at sector {d} and has {d} sector(s) of {d} Bytes\n", .{ image_start, count, VIRTUAL_SECTOR_SIZE });

    var write_count: u64 = 0;
    var image_blocks: [VIRTUAL_SECTOR_SIZE]u8 = undefined;
    try iso_file.seekTo(image_start * SECTOR_SIZE);
    while (true) {
        const image_read_bytes = iso_file.read(image_blocks[0..]) catch |err| {
            std.debug.print("Unable to read image: {s}\n", .{@errorName(err)});
            return err;
        };
        if (image_read_bytes == 0) {
            return WriteError.ReadEarlyExitError;
        }
        _ = output_file.write(image_blocks[0..image_read_bytes]) catch |err| {
            std.debug.print("Unable to write image: {s}\n", .{@errorName(err)});
            return err;
        };
        write_count += 1;
        if (write_count == count) {
            break;
        }
    }
    try output_file.flush();
}
