const std  = @import("std");
const zine = @import("zine");
const ziggy = @import("ziggy").ziggy;

const Foo = struct {
    name: []const u8,
    number: i32,
};

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target   = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name    = "zine_site",
        .linkage = .static,
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const make_db = CreatePhotoDatabase.create(b, b.path("assets"));

    // TODO: make "mipmaps" of the 4k images at build-time so that thumbnails can be shown

    //const build_site = zine.website(b, zine_options);
    //b.getInstallStep().dependOn(&build_site.step);

    const zine_options: zine.Options = .{ .debug = .{ .optimize = optimize } };
    const serve = b.step("serve", "Start the Zine dev server");
    const run_zine = zine.serve(b, zine_options);
    run_zine.step.dependOn(&make_db.step);
    serve.dependOn(&run_zine.step);
}

const CreatePhotoDatabase = struct {
    const Self = @This();
    step: std.Build.Step,
    photos_dir: std.Build.LazyPath,

    pub fn create(b: *std.Build, photos_dir: std.Build.LazyPath) *Self {
        const self = b.allocator.create(Self) catch unreachable;
        self.* = .{ 
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "Create photo DB",
                .owner = b,
                .makeFn = Self.make,
            }),
            .photos_dir = photos_dir.dupe(b),
        };
        photos_dir.addStepDependencies(&self.step);
        return self;
    }
    
    pub fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;

        const b = step.owner;
        const self: *Self = @fieldParentPtr("step", step);

        step.clearWatchInputs();
        _ = try step.addDirectoryWatchInput(self.photos_dir);

        const allocator = b.allocator;

        var file_list = std.array_list.Managed([]const u8).init(allocator);
        defer file_list.deinit();

        const path = self.photos_dir.getPath3(b, step);
        var dir = path.root_dir.handle.openDir(path.subPathOrDot(), .{ .iterate = true, }) catch |err| {
            return step.fail("unable to open directory '{f}': {s}", .{ path, @errorName(err), });
        };
        defer dir.close();

        var dir_iter = try dir.walk(allocator);
        defer dir_iter.deinit();

        while (try dir_iter.next()) |asset| {
            if (asset.kind == .file) {
                try file_list.append(b.dupe(asset.path));
            }
        }

        var buffer: [512]u8 = undefined;

        // TODO: Use lazyPath for this file
        const db_path = "db.ziggy";
        const out = std.fs.cwd().createFile(db_path, .{ }) catch |err| {
            return step.fail("unable to open file '{s}': {s}", .{ db_path, @errorName(err), });
        };
        defer out.close();
        try out.setEndPos(0);

        var writer = out.writer(&buffer);
        defer writer.end() catch unreachable;

        const stringify_options: ziggy.serializer.StringifyOptions = .{ .whitespace = .space_4, };
        try ziggy.stringify(file_list.items, stringify_options, &writer.interface);
    }
};
