const builtin = @import("builtin");
const std = @import("std");
const allocator = std.debug.global_allocator;
const fmt = std.fmt;
const File = std.fs.File;
const io = std.io;
const mem = std.mem;
const process = std.process;
const warn = std.debug.warn;

const VIRTUAL_SECTOR_SIZE = 512;
const SECTOR_SIZE = 2048;
const BOOT_SECTOR = 17;

const FormatError = error{
    BadBootRecordIndicator,
    BadIso9660Identifier,
    BadBootSystemIdentifier,
    Bad55Checksum,
    BadAAChecksum,
    BadBootMediaType,
};

pub fn main() !void {
    var args_iter = process.args();
    var set_output_file = false;
    var output_filename: ?[]u8 = null;
    var iso_filename: ?[]u8 = null;

    const exe = try unwrapArg(args_iter.next(allocator).?);
    while (args_iter.next(allocator)) |arg_or_err| {
        const arg = try unwrapArg(arg_or_err);
        if (set_output_file) {
            output_filename = arg;
            set_output_file = false;
        } else if (mem.eql(u8, arg, "-v")) {
            warn("v0\n");
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
    var iso_file = try File.openRead(iso_filename.?);
    defer iso_file.close();

    if (output_filename == null) {
        var stdout_file = try io.getStdIn();
        return writeImage(&iso_file, &stdout_file);
    }
    var output_file = try File.openWrite(output_filename.?);
    defer output_file.close();
    return writeImage(&iso_file, &output_file);
}

fn usage(exe: []const u8) !void {
    @setEvalBranchQuota(1500);
    const str =
        \\{} [-h] [-v] [-o outputfilename] cd-image
        \\Script will try to extract an El Torito image from a
        \\bootable CD (or cd-image) given by <cd-image> and write
        \\the data extracted to STDOUT or to a file.
        \\   -h:        Print this message.
        \\   -v:        Print version of this program.
        \\   -o <file>: Write extracted data to file <file> instead of STDOUT
        \\
    ;
    warn(str, exe);
    return error.Invalid;
}

fn unwrapArg(arg: anyerror![]u8) ![]u8 {
    return arg catch |err| {
        warn("Unable to parse command line: {}\n", err);
        return err;
    };
}

fn writeImage(iso_file: *File, output_file: *File) !void {
    var boot_entry: [VIRTUAL_SECTOR_SIZE]u8 = undefined;
    try iso_file.seekTo(BOOT_SECTOR * SECTOR_SIZE);
    const boot_entry_bytes = iso_file.read(boot_entry[0..]) catch |err| {
        warn("Unable to read boot sector: {}\n", @errorName(err));
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
    const unused_1 = boot_entry[39..71];
    const boot_catalog_ptr = mem.readIntSliceNative(u32, boot_entry[71..75]);

    warn("==== Boot Record Volume ====\n");
    warn("Boot Record Indicator: {}\n", boot_indicator);
    warn("ISO 9660 identifier: {}\n", iso_identifier);
    warn("Descriptor Version: {}\n", desc_version);
    warn("Specification: {}\n", spec);
    warn("Boot Catalog Pointer: {}\n", boot_catalog_ptr);

    if (boot_indicator != 0) {
        return FormatError.BadBootRecordIndicator;
    }
    if (!mem.eql(u8, iso_identifier, "CD001")) {
        return FormatError.BadIso9660Identifier;
    }

    // mem.eql checks for length and spec is 32 bytes while the string is 23.
    // the spec is zero-padded so we're using the slice for validation
    if (!mem.eql(u8, spec[0..23], "EL TORITO SPECIFICATION")) {
        return FormatError.BadBootSystemIdentifier;
    }

    var catalog_entry: [VIRTUAL_SECTOR_SIZE]u8 = undefined;
    try iso_file.seekTo(boot_catalog_ptr * SECTOR_SIZE);
    const catalog_entry_bytes = iso_file.read(catalog_entry[0..]) catch |err| {
        warn("Unable to read boot sector: {}\n", @errorName(err));
        return err;
    };
    if (catalog_entry_bytes != VIRTUAL_SECTOR_SIZE) {
        return error.ReadError;
    }

    // Specification: https://pdos.csail.mit.edu/6.828/2018/readings/boot-cdrom.pdf, Page 9/20
    const header = catalog_entry[0];
    const platform = catalog_entry[1];
    const manufacturer = catalog_entry[4..28];
    const checksum_zero = catalog_entry[28..30]; // TODO: sum of these two bytes are supposed to equal zero?
    const five = catalog_entry[30];
    const aa = catalog_entry[31];

    warn("==== Validation Entry ====\n");
    warn("header: {X}\n", header);
    warn("platform: {X}\n", platform);
    warn("manufacturer: {}\n", manufacturer);
    warn("five checksum: {X}\n", five);
    warn("aa checksum: {X}\n", aa);

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
    const load_segment = mem.readIntSliceNative(u16, initial_entry[2..4]);
    const system_type = initial_entry[4];
    const sector_count = mem.readIntSliceNative(u16, initial_entry[6..8]);
    const image_start = mem.readIntSliceNative(u32, initial_entry[8..12]);

    warn("==== Initial (default) Entry ====\n");
    warn("bootable: {X}\n", bootable);
    warn("boot media type: {X}\n", boot_media_type);
    warn("load segment: {X}\n", load_segment);
    warn("system type: {X}\n", system_type);
    warn("sector count: {X}\n", sector_count);
    warn("image start: {}\n", image_start);
    // ($boot, $media, $loadSegment, $systemType, $unUsed, $sCount, $imgStart, $unUsed)=unpack( "CCvCCvVC", $initialEntry);

    const real_count = switch (boot_media_type) {
        0 => blk: {
            warn("no boot media emulation found\n");
            break :blk u32(0);
        },
        1 => blk: {
            warn("boot media type is: 1.22meg floppy\n");
            break :blk (1200 * 1024) / VIRTUAL_SECTOR_SIZE;
        },
        2 => blk: {
            warn("boot media type is: 1.44meg floppy\n");
            break :blk (1440 * 1024) / VIRTUAL_SECTOR_SIZE;
        },
        3 => blk: {
            warn("boot media type is: 2.88meg floppy\n");
            break :blk (2880 * 1024) / VIRTUAL_SECTOR_SIZE;
        },
        4 => blk: {
            warn("boot media type is: hard disk\n");
            // TODO: starthere
            break :blk 420;
        },
        else => {
            warn("unknown boot media emulation found\n");
            return error.BadBootMediaType;
        },
    };
    warn("calc count: {}\n", real_count);
}
