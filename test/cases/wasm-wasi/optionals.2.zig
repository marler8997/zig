pub fn main() u8 {
    var x: ?u8 = 5;
    return x orelse unreachable - 5;
}

// run
//
