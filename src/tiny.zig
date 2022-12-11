//! This file contains functions for turning source code into a Listing

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Listing = @import("listing.zig").Listing;

//re-exports
pub const readListing = @import("listing.zig").read;
