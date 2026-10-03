const std = @import("std");

const assert = std.debug.assert;

pub const tags_scanned_max: u32 = 8192;
pub const attributes_scanned_max: u32 = 64;
pub const ticket_marker: []const u8 = "?ticket=";
pub const ticket_terminators: []const u8 = "\"'&\\ \t\r\n>";

pub fn field_value(document: []const u8, name: []const u8) ?[]const u8 {
    assert(name.len != 0);

    const tag = tag_named(document, name) orelse return null;

    assert(tag.len != 0);

    return attribute(tag, "value");
}

pub fn field_present(document: []const u8, name: []const u8) bool {
    assert(name.len != 0);

    return tag_named(document, name) != null;
}

pub fn service_ticket(document: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, document, ticket_marker) orelse return null;
    const body = document[at + ticket_marker.len ..];

    const end = std.mem.findAny(u8, body, ticket_terminators) orelse body.len;

    if (end == 0) return null;

    return body[0..end];
}

fn tag_named(document: []const u8, name: []const u8) ?[]const u8 {
    assert(name.len != 0);

    var cursor: usize = 0;
    var scanned: u32 = 0;

    while (scanned < tags_scanned_max) : (scanned += 1) {
        const opened = std.mem.findScalarPos(u8, document, cursor, '<') orelse return null;
        const closed = std.mem.findScalarPos(u8, document, opened, '>') orelse return null;

        assert(closed > opened);

        const tag = document[opened + 1 .. closed];

        cursor = closed + 1;

        const candidate = attribute(tag, "name") orelse continue;

        if (std.mem.eql(u8, candidate, name)) return tag;
    }

    return null;
}

pub fn attribute(tag: []const u8, key: []const u8) ?[]const u8 {
    assert(key.len != 0);

    var cursor: usize = 0;
    var scanned: u32 = 0;

    while (scanned < attributes_scanned_max) : (scanned += 1) {
        const at = std.mem.findPos(u8, tag, cursor, key) orelse return null;
        const after = at + key.len;

        cursor = after;

        if (at != 0 and !is_boundary(tag[at - 1])) continue;
        if (after == tag.len) return null;
        if (tag[after] != '=') continue;

        const opened = after + 1;

        if (opened == tag.len) return null;
        if (!is_quote(tag[opened])) continue;

        const body = tag[opened + 1 ..];
        const closed = std.mem.findScalar(u8, body, tag[opened]) orelse return null;

        return body[0..closed];
    }

    return null;
}

fn is_boundary(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', '/' => true,
        else => false,
    };
}

fn is_quote(byte: u8) bool {
    return byte == '"' or byte == '\'';
}

test {
    _ = @import("html_fuzz.zig");
}

test "field_value reads a hidden input regardless of attribute order" {
    const name_first =
        \\<form>
        \\  <input type="hidden" name="_csrf" value="ABC123-def456_GHI" />
        \\</form>
    ;

    const value_first =
        \\<form>
        \\  <input value="ABC123-def456_GHI" name="_csrf" type="hidden">
        \\</form>
    ;

    try std.testing.expectEqualStrings(
        "ABC123-def456_GHI",
        field_value(name_first, "_csrf").?,
    );

    try std.testing.expectEqualStrings(
        "ABC123-def456_GHI",
        field_value(value_first, "_csrf").?,
    );
}

test "field_value accepts single quoted attributes" {
    const document = "<input name='_csrf' value='single-quoted'>";

    try std.testing.expectEqualStrings("single-quoted", field_value(document, "_csrf").?);
}

test "field_value does not match an attribute suffix" {
    const document =
        \\<input data-name="_csrf" value="decoy">
        \\<input name="real" value="kept">
    ;

    try std.testing.expect(field_value(document, "_csrf") == null);
    try std.testing.expectEqualStrings("kept", field_value(document, "real").?);
}

test "field_value stays inside the tag it matched" {
    const document =
        \\<input name="_csrf">
        \\<input name="other" value="not-the-csrf">
    ;

    try std.testing.expect(field_value(document, "_csrf") == null);
}

test "field_value tolerates a stray angle bracket inside a tag" {
    const document = "<input name=\"a\" value=\"x < y\">";

    try std.testing.expectEqualStrings("x < y", field_value(document, "a").?);
}

test "field_present finds a valueless input" {
    const document = "<input type=\"text\" name=\"mfa-code\" maxlength=\"6\">";

    try std.testing.expect(field_present(document, "mfa-code"));
    try std.testing.expect(!field_present(document, "_csrf"));
}

test "service_ticket reads the ticket out of the redirect url" {
    const document =
        \\<script>
        \\  response_url = "https://sso.garmin.com/sso/embed?ticket=ST-0123456-abcXYZdef-cas";
        \\</script>
    ;

    try std.testing.expectEqualStrings(
        "ST-0123456-abcXYZdef-cas",
        service_ticket(document).?,
    );
}

test "service_ticket stops at a following query parameter" {
    const document = "location = 'https://sso.garmin.com/sso/embed?ticket=ST-9-xyz&next=1';";

    try std.testing.expectEqualStrings("ST-9-xyz", service_ticket(document).?);
}

test "extractors report absence with null" {
    try std.testing.expect(field_value("<form></form>", "_csrf") == null);
    try std.testing.expect(service_ticket("no ticket here") == null);
    try std.testing.expect(service_ticket("?ticket=") == null);
}
