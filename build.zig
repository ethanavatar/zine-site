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

    const make_db = CreatePhotoDatabase.create(b, .{
        .photos_dir = b.path("assets/photos"),
        .db_file    = b.path("assets/db.ziggy"),
        .base       = b.path("assets/"),
    });

    // TODO: make "mipmaps" of the 4k images at build-time so that thumbnails can be shown

    //const build_site = zine.website(b, zine_options);
    //b.getInstallStep().dependOn(&build_site.step);

    const zine_options: zine.Options = .{
        //.debug = .{ .optimize = optimize }
    };
    const serve = b.step("serve", "Start the Zine dev server");
    const run_zine = zine.serve(b, zine_options);
    run_zine.step.dependOn(&make_db.step);
    serve.dependOn(&run_zine.step);
}

const GalleryManifest = struct {
    name: []const u8,
    thumbnail: []const u8,
};

const Gallery = struct {
    name: []const u8,
    thumbnail: []const u8,
    path: []const u8,
    photos: ?[][]const u8,
};

const CreatePhotoDatabase = struct {
    const Self = @This();
    const Options = struct {
        photos_dir: std.Build.LazyPath,
        db_file:    std.Build.LazyPath,
        base:       std.Build.LazyPath,
    };
    step: std.Build.Step,
    options: Options,

    pub fn create(b: *std.Build, options: Options) *Self {
        const self = b.allocator.create(Self) catch unreachable;
        self.* = .{ 
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "Create photo DB",
                .owner = b,
                .makeFn = Self.make,
            }),
            .options = .{
                .photos_dir = options.photos_dir.dupe(b),
                .db_file    = options.db_file.dupe(b),
                .base       = options.base.dupe(b),
            },
        };
        options.photos_dir.addStepDependencies(&self.step);
        options.db_file.addStepDependencies(&self.step);
        return self;
    }
    
    pub fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;

        const b = step.owner;
        const self: *Self = @fieldParentPtr("step", step);

        step.clearWatchInputs();
        _ = try step.addDirectoryWatchInput(self.options.photos_dir);

        const allocator = b.allocator;

        const photos_path = self.options.photos_dir.getPath3(b, step);
        var dir = photos_path.root_dir.handle.openDir(photos_path.subPathOrDot(), .{ .iterate = true, }) catch |err| {
            return step.fail("unable to open directory '{f}': {s}", .{ photos_path, @errorName(err), });
        };
        defer dir.close();

        var galleries = std.StringArrayHashMap(Gallery).init(allocator);
        defer galleries.deinit();

        var photos = std.StringArrayHashMap(std.array_list.Managed([]const u8)).init(allocator);
        defer photos.deinit();

        const base_path = self.options.base.getPath3(b, step).subPathOrDot();
        const relative_photos_path = try std.fs.path.relative(allocator, base_path, photos_path.subPathOrDot());

        {
            var dir_iter = try dir.walk(allocator);
            defer dir_iter.deinit();

            while (try dir_iter.next()) |asset| {
                if (std.mem.eql(u8, asset.basename, "_gallery.ziggy")) {
                    const manifest = try dir.openFile(asset.path, .{ }); 
                    defer manifest.close();

                    const stat = try manifest.stat();
                    const size = stat.size;

                    const source = try allocator.alloc(u8, size);
                    defer allocator.free(source);

                    _ = try manifest.read(source);
                    const gallery = try ziggy.parseLeaky(
                        GalleryManifest,
                        allocator,
                        try allocator.dupeZ(u8, source),
                        .{}
                    );

                    const gallery_path = std.fs.path.dirname(asset.path) orelse unreachable;
                    const thumbnail_path = try std.mem.replaceOwned(
                        u8,
                        allocator,
                        try std.fs.path.join(allocator, &[_][]const u8{
                            relative_photos_path,
                            gallery_path,
                            gallery.thumbnail
                        }), "\\", "/"
                    );

                    const full_gallery_path = try std.mem.replaceOwned(
                        u8,
                        allocator,
                        try std.fs.path.join(allocator, &[_][]const u8{
                            relative_photos_path,
                            gallery_path,
                        }), "\\", "/"
                    );

                    try galleries.put(b.dupe(gallery_path), .{
                        .name = b.dupe(gallery.name),
                        .thumbnail = thumbnail_path,
                        .path = full_gallery_path,
                        .photos = null,
                    });

                    const list = std.array_list.Managed([]const u8).init(allocator);
                    try photos.put(b.dupe(gallery_path), list);
                }
            }
        }

        var dir_iter = try dir.walk(allocator);
        defer dir_iter.deinit();

        const photo_extensions = std.StaticStringMap(void).initComptime(.{
            .{ ".jpg",  void },
        });

        while (try dir_iter.next()) |asset| {
            if (asset.kind != .file) continue;

            const extension = std.fs.path.extension(asset.basename);
            if (photo_extensions.get(extension)) |ext| {
                _ = ext;

                const gallery_path = std.fs.path.dirname(asset.path) orelse unreachable;

                if (photos.getPtr(gallery_path)) |list| {

                    const photo_path = try std.mem.replaceOwned(
                        u8,
                        allocator,
                        try std.fs.path.join(allocator, &[_][]const u8{
                            relative_photos_path,
                            gallery_path,
                            asset.basename
                        }), "\\", "/"
                    );

                    try list.append(photo_path);
                }
            }
        }

        for (galleries.values(), photos.values()) |*gallery, *gallery_photos| {
            gallery.photos = gallery_photos.items;
        }

        const db_path = self.options.db_file.getPath3(b, step);
        const out = std.fs.cwd().createFile(db_path.subPathOrDot(), .{ }) catch |err| {
            return step.fail("unable to open file '{f}': {s}", .{ db_path, @errorName(err), });
        };
        defer out.close();
        try out.setEndPos(0);

        var buffer: [256]u8 = undefined;
        var writer = out.writer(&buffer);
        defer writer.end() catch unreachable;

        const stringify_options: ziggy.serializer.StringifyOptions = .{ .whitespace = .space_4, };
        try ziggy.stringify(galleries.values(), stringify_options, &writer.interface);
    }
};
